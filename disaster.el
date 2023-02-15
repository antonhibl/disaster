;;; disaster.el --- Disassemble C, C++ or Fortran code under cursor -*- lexical-binding: t; -*-

;; Copyright (C) 2013-2022 Justine Tunney.

;; Author: Justine Tunney <jtunney@gmail.com>
;;         Abdelhak Bougouffa <abougouffa@fedoraproject.org>
;; Maintainer: Abdelhak Bougouffa <abougouffa@fedoraproject.org>
;; Created: 2013-03-02
;; Version: 1.0
;; Package-Requires: ((emacs "27"))
;; Keywords: tools c
;; URL: https://github.com/jart/disaster

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; ![Screenshot of a C example](screenshot-c.png)
;;
;; ![Screenshot of a Fortran example](screenshot-fortran.png)
;;
;; Disaster lets you press `C-c d` to see the compiled assembly code for the
;; C, C++ or Fortran file you're currently editing. It even jumps to and
;; highlights the line of assembly corresponding to the line beneath your cursor.
;;
;; It works by creating a `.o` file using `make` (if you have a Makefile), or
;; `cmake` (if you have a `compile_commands.json` file) or the default system
;; compiler. It then runs that file through `objdump` to generate the
;; human-readable assembly.

;;; Installation:

;; Make sure to place `disaster.el` somewhere in the `load-path`, then you should
;; be able to run `M-x disaster`. If you want, you add the following lines to
;; your `.emacs` file to register the `C-c d` shortcut for invoking `disaster`:
;;
;; ```elisp
;; (add-to-list 'load-path "/PATH/TO/DISASTER")
;; (require 'disaster)
;; (define-key c-mode-map (kbd "C-c d") 'disaster)
;; (define-key fortran-mode-map (kbd "C-c d") 'disaster)
;; ```

;; #### Doom Emacs

;; For Doom Emacs users, you can add this snippet to your `packages.el`.
;;
;; ```elisp
;; (package! disaster
;;   :recipe (:host github :repo "jart/disaster"))
;; ```
;;
;; And this to your `config.el`:
;;
;; ```elisp
;; (use-package! disaster
;;   :commands (disaster)
;;   :init
;;   ;; If you prefer viewing assembly code in `nasm-mode` instead of `asm-mode`
;;   (setq disaster-assembly-mode 'nasm-mode)
;;
;;   (map! :localleader
;;         :map (c++-mode-map c-mode-map fortran-mode-map)
;;         :desc "Disaster" "d" #'disaster))
;; ```

;;; Code:

(require 'json)
(require 'vc)
(load-file "~/.emacs.d/beacon/beacon.el")

(defgroup disaster nil
  "Disassemble C/C++ under cursor (Works best with Clang)."
  :prefix "disaster-"
  :group 'tools)

(defcustom disaster-make-flags "-k"
  "Command line options to pass to make if a Makefile is found."
  :group 'disaster
  :type 'string)

(defcustom disaster-assembly-mode 'asm-mode
  "Which mode to use to view assembly code."
  :group 'disaster
  :type '(choice asm-mode nasm-mode))

(defcustom disaster-cc (or (getenv "CC") "cc")
  "The command for your C compiler."
  :group 'disaster
  :type 'string)

(defcustom disaster-cxx (or (getenv "CXX") "c++")
  "The command for your C++ compiler."
  :group 'disaster
  :type 'string)


(defcustom disaster-fortran (or (getenv "FORTRAN") "gfortran")
  "The command for your Fortran compiler."
  :group 'disaster
  :type 'string)

(defcustom disaster-cflags (or (getenv "CFLAGS")
                               "-march=native")
  "Command line options to use when compiling C."
  :group 'disaster
  :type 'string)

(defcustom disaster-cxxflags (or (getenv "CXXFLAGS")
                                 "-march=native")
  "Command line options to use when compiling C++.!"
  :group 'disaster
  :type 'string)


(defcustom disaster-fortranflags (or (getenv "FORTRANFLAGS")
                                     "-march=native")
  "Command line options to use when compiling Fortran."
  :group 'disaster
  :type 'string)

(defcustom disaster-objdump
  (concat (if (eq system-type 'darwin) "gobjdump" "objdump")
          " -d -m aarch64 -Sl --no-show-raw-insn")
  "The command name and flags for running objdump."
  :group 'disaster
  :type 'string)

(defcustom disaster-buffer-compiler "*disaster-compilation*"
  "Buffer name to use for assembler output."
  :group 'disaster
  :type 'string)

(defcustom disaster-buffer-assembly "*disaster-assembly*"
  "Buffer name to use for objdump assembly output."
  :group 'disaster
  :type 'string)

(defcustom disaster-project-root-files
  (list (list ".projectile")    ;; Projectile project root.
        (list "setup.py"        ;; Python apps.
              "package.json")   ;; node.js apps.
        (list "CMakeLists.txt") ;; CMake files are sometimes in subdirectories.
        (list "Makefile"))      ;; Makefiles are sometimes in subdirectories.
  "List of lists of files that may indicate software project root directory.
Sublist are ordered from highest to lowest precedence."
  :group 'disaster
  :type '(repeat (repeat string)))

(defcustom disaster-c-regexp "\\.c$"
  "Regexp for C source files."
  :group 'disaster
  :type 'regexp)

(defcustom disaster-cpp-regexp "\\.c\\(c\\|pp\\|xx\\)$"
  "Regexp for C++ source files."
  :group 'disaster
  :type 'regexp)

(defcustom disaster-fortran-regexp "\\.f\\(or\\|90\\|95\\|0[38]\\)?$"
  "Regexp for Fortran source files."
  :group 'disaster
  :type 'regexp)

;;;###autoload
(defvar disaster-find-build-root-functions nil
  "Functions to call to get the build root directory from the project directory.
If nil is returned, the next function will be tried.  If all
functions return nil, the project root directory will be used as
the build directory.")

(defun disaster-run-objdump (asm-file)
  "Run objdump on the given assembly file and return the buffer with the assembly code."
  (let ((obj-file (concat (file-name-sans-extension asm-file) ".o"))
        (asm-buffer (get-buffer-create "*disaster*")))
    (with-current-buffer asm-buffer
      (goto-char (point-max))
      (insert (shell-command-to-string (format "%s -D %s" disaster-objdump obj-file)))
      (disaster--setup-assembly-mode))
    asm-buffer))

(defun disaster-run-clang (filename)
  "Run clang on the given file and return the buffer with the assembly code."
  (let ((asm-buffer (get-buffer-create "*disaster*")))
    (with-current-buffer asm-buffer
      (erase-buffer)  ; clear the buffer before running clang
      (shell-command (format "clang -arch arm64 -S -o %s.s %s"
                             (file-name-sans-extension filename) filename))
      (find-file (concat (file-name-sans-extension filename) ".s"))
      (disaster--setup-assembly-mode))))

(defun disaster-get-object-file (filename line-number)
  "Get the object file path for the given file name and line number."
  (let* ((cwd (file-name-directory (expand-file-name filename)))
         (obj-name (concat (file-name-sans-extension filename) ".o"))
         (cc (if (string-match-p disaster-cpp-regexp filename) "c++" "cc"))
         (obj-file (concat cwd obj-name)))
    (if (file-exists-p obj-file)
        obj-file
      (progn
        (shell-command (format "%s -g -c %s" cc filename))
        (rename-file (concat cwd (file-name-sans-extension filename) ".o")
                     obj-file)
        obj-file))))

(defun disaster-create-compile-command-make (make-root cwd rel-obj obj-file proj-root rel-file file)
  "Create compile command for a Make-based project.
MAKE-ROOT: path to build root,
CWD: path to current source file,
REL-OBJ: path to object file (relative to project root),
OBJ-FILE: full path to object file (build root!)
PROJ-ROOT: path to project root, REL-FILE FILE."
  (if make-root
      ;; if-then
      (cond ((equal cwd make-root)
             (format "make %s %s" disaster-make-flags (shell-quote-argument rel-obj)))
            (t (format "make %s -C %s %s"
                       disaster-make-flags make-root rel-obj)))
    ;; if-else
    (cond ((string-match-p disaster-cpp-regexp file)
           (format "%s %s -g -c -o %s %s"
                   disaster-cxx disaster-cxxflags
                   (shell-quote-argument obj-file) (shell-quote-argument file)))
          ((string-match-p disaster-c-regexp file)
           (format "%s %s -g -c -o %s %s"
                   disaster-cc disaster-cflags
                   (shell-quote-argument obj-file) (shell-quote-argument file)))
          ((string-match-p disaster-fortran-regexp file)
           (format "%s %s -g -c -o %s %s"
                   disaster-fortran disaster-fortranflags
                   (shell-quote-argument obj-file) (shell-quote-argument file)))
          (t (warn "File %s do not seems to be a C, C++ or Fortran file." file)))))

(defun disaster-create-compile-command-cmake (make-root cwd rel-obj obj-file proj-root rel-file)
  "Create compile command for a CMake-based project.
MAKE-ROOT: path to build root,
CWD: path to current source file,
REL-OBJ: path to object file (relative to project root),
OBJ-FILE: full path to object file (build root!)
PROJ-ROOT: path to project root, REL-FILE FILE."
  (let* ((json-object-type 'hash-table)
         (json-array-type 'list)
         (json-key-type 'string)
         (json (json-read-file (concat make-root "/compile_commands.json"))))
    (catch 'compile-command
      (dolist (obj json)
        (when (string-equal (gethash "file" obj) (concat proj-root rel-file))
          (throw 'compile-command (gethash "command" obj)))))))

(defun disaster-get-object-file-path-cmake (compile-cmd)
  "Get the .o object file name from a full COMPILE-CMD."
  (let* ((parts (split-string compile-cmd " "))
         (break-on-next nil))
    (catch 'object-file
      (dolist (part parts)
        (if (string-equal "-o" part)
            (setq break-on-next t)
          (when break-on-next
            (throw 'object-file part)))))))

(defun disaster-create-compile-command (use-cmake make-root cwd rel-obj obj-file proj-root rel-file file)
  "Create the actual compile command.
USE-CMAKE: non NIL to use CMake, NIL to use Make or default compiler options,
MAKE-ROOT: path to build root,
CWD: path to current source file,
REL-OBJ: path to object file (relative to project root),
OBJ-FILE: full path to object file (build root!)
PROJ-ROOT: path to project root, REL-FILE FILE."
  (if use-cmake
      (disaster-create-compile-command-cmake make-root cwd rel-obj obj-file proj-root rel-file)
    (disaster-create-compile-command-make make-root cwd rel-obj obj-file
                                          proj-root rel-file file)))

(defun disaster--setup-assembly-mode ()
  "Set up `asm-mode` for the *disaster* buffer."
  (setq tab-width 4)
  (setq-local tab-stop-list (number-sequence 4 200 4))
  (setq-local truncate-lines t))

(defun disaster--highlight-line (line-text gobjdump-output)
  "Highlight the line matching LINE-TEXT in the asm buffer and blink line."
  (with-current-buffer "*disaster*"
    (setq buffer-read-only nil)
    (goto-char (point-min))
    (when (re-search-forward (concat "^.*" (regexp-quote line-text) ".*$") nil t)
      (let ((overlay (make-overlay (line-beginning-position) (line-end-position))))
        (overlay-put overlay 'face 'region)
        (overlay-put overlay 'priority 1)
        (overlay-put overlay 'help-echo "Current line")
        (beacon-blink))
      (message "Line '%s' highlighted." line-text))
    (message "Line '%s' not found." line-text)))

;;;###autoload
(defun disaster (&optional file line)
  "Show assembly code for current LINE of C/C++ FILE in a new buffer and window called *disaster*."
  (interactive)
  (let* ((filename (or file (file-name-nondirectory (buffer-file-name))))
         (line-number (or line (line-number-at-pos)))
         (disaster-run-function (intern (completing-read "Select disassembler function: " '(disaster-run-clang disaster-run-objdump) nil t))))
    (if (or (string-match-p disaster-c-regexp filename)
            (string-match-p disaster-cpp-regexp filename)
            (string-match-p disaster-fortran-regexp filename))
        (let* ((gobjdump-output nil)
               (asm-buffer (funcall disaster-run-function filename))
               (line-text (buffer-substring-no-properties
                           (point-at-bol)
                           (point-at-eol))))
          (setq gobjdump-output (with-current-buffer asm-buffer
                                  (buffer-string)))
          (with-current-buffer asm-buffer
            (disaster--highlight-line line-text gobjdump-output))
          (with-current-buffer (get-buffer-create "*disaster*")
            (setq buffer-read-only nil)
            (goto-char (point-max))
            (insert-buffer-substring asm-buffer)
            (asm-mode))
          (pop-to-buffer "*disaster*"))
      (message "Not a C, C++ or Fortran source file."))))

;; Choose the run function based on the OS
(defcustom disaster-run-function (if (eq system-type 'darwin) 'disaster-run-clang 'disaster-run-objdump)
  "The function to run to disassemble the given file."
  :group 'disaster
  :type 'symbol)

(defun disaster--shadow-non-assembly-code ()
  "Scans current buffer, which should be in `asm-mode'.
Uses the standard `shadow' face for lines that don't appear to contain
assembly code."
  (remove-overlays)
  (save-excursion
    (goto-char 0)
    (while (not (eobp))
      (beginning-of-line)
      (if (not (looking-at "[ \t]+[a-f0-9]+:[ \t]+"))
          (let ((eol (save-excursion (end-of-line) (point))))
            (overlay-put (make-overlay (point) eol)
                         'face 'shadow)))
      (forward-line))))

(defun disaster--find-parent-dirs (&optional file)
  "Return a list of parent directories with trailing slashes.

For example:

    (disaster--find-parent-dirs \"/home/jart/disaster-disaster.el\")
    => (\"/home/jart/\" \"/home/\" \"/\")

FILE default to `w/function buffer-file-name'."
  (let ((res nil)
        (dir (file-name-directory
              (expand-file-name (or file (buffer-file-name))))))
    (while dir
      (setq res (cons dir res)
            dir (if (string-match "/[^/]+/$" dir)
                    (substring dir 0 (+ 1 (match-beginning 0))))))
    (reverse res)))

(defun disaster--dir-has-file (dir file)
  "Return t if DIR contain FILE (or any file if FILE is a list).

For example:

    (disaster--dir-has-file \"/home/jart/\" \".bashrc\")
    (disaster--dir-has-file \"/home/jart/\" (list \".bashrc\" \".screenrc\"))"
  (let ((res nil)
        (dir (file-name-as-directory dir))
        (files (if (listp file)
                   file
                 (list file))))
    (while (and files (not res))
      (setq res (file-exists-p (concat dir (car files)))
            files (cdr files)))
    res))

(defun disaster-find-project-root (&optional looks file)
  "General-purpose Heuristic to detect bottom directory of project.

First, this will try to use `(vc-root-dir)' to guess the project
root directory, and falls back to manual check wich works by scanning
parent directories of FILE (using `disaster--find-parent-dirs') for certain
types of files like a `.projectile` file or a `Makefile` (which is less
preferred).

The canonical structure of LOOKS is a list of lists of files
to look for in each parent directory where sublists are ordered
from highest precedence to lowest.  However you may specify
LOOKS as a single string or a list of strings for your
convenience. If LOOKS is not specified, it'll default to
`disaster-project-root-files'."
  (let* ((buffer (get-file-buffer (or file (buffer-file-name))))
         (res (when buffer
                (with-current-buffer buffer
                  (when (vc-root-dir)
                    (expand-file-name (vc-root-dir))))))
         (looks (if looks
                    (if (listp looks)
                        (if (listp (car looks))
                            looks
                          (list looks))
                      (list (list looks)))
                  disaster-project-root-files))
         (parent-dirs (disaster--find-parent-dirs file)))
    (while (and looks (null res))
      (let ((parents parent-dirs))
        (while (and parents (null res))
          (setq res (when (disaster--dir-has-file (car parents) (car looks))
                      (car parents))
                parents (cdr parents))))
      (setq looks (cdr looks)))
    res))

(defun disaster-find-build-root (use-cmake project-root)
  "Find the root of build directory.
USE-CMAKE: non nil to use CMake's compile_commands.json,
PROJECT-ROOT: root directory of the project."
  (if use-cmake
      (progn
        (let* ((json-object-type 'hash-table)
               (json-array-type 'list)
               (json-key-type 'string)
               (json (json-read-file (concat project-root "/compile_commands.json"))))
          (gethash "directory" (car json))))
    (and project-root
         (or (let (build-root
                   (funcs disaster-find-build-root-functions))
               (while (and (null build-root) funcs)
                 (setq build-root (funcall (car funcs) project-root)
                       funcs (cdr funcs)))
               (and build-root
                    (file-name-as-directory build-root)))
             project-root))))

(provide 'disaster)

;;; disaster.el ends here
