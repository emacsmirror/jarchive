;;; jarchive.el --- Open project dependencies in jar archives -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Danny Freeman
;; Authors: Danny Freeman <danny@dfreeman.email>
;; Maintainer: Danny Freeman <danny@dfreeman.email>>
;; Version: 0.1.0
;; Keywords: tools, languages, jvm, java, clojure
;; URL: https://git.sr.ht/~dannyfreeman/jarchive
;; Package-Requires: ((emacs "26.1"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; Jarchive extends Emacs to allow navigation into files contained within .jar archives.
;; Works great with Eglot and JVM language servers like clojure-lsp!
;;
;; Special shout out to João Távora for his advice and feedback while I wrote this package and for
;; his work on Eglot.

;;; Code:
(require 'arc-mode)
(require 'cl-lib)
(require 'seq)
(require 'url-parse)

(defconst jarchive--uri-regex
  (rx
   line-start
   (or "jar:file://" "zipfile://")
   ;; match group 1, the jar file location
   (group "/" (* not-newline) ".jar")
   ;; Delimiter between the jar and the file inside the jar
   (or "!" "::")
   ;; match the leading directory delimiter /,
   ;; archvie mode expects none so it's outside match group 2
   (zero-or-one "/")
   ;; match group 2, the file within the archive
   (group (* not-newline) "." (+ alphanumeric))
   line-end)
  "A regex for matching paths to a jar file and a file path into the jar file.
Delimited by `!'.")

(defun jarchive--match! (uri)
  (string-match jarchive--uri-regex uri))

(defun jarchive--match-jar (uri)
  (substring uri (match-beginning 1) (match-end 1)))

(defun jarchive--match-file (uri)
  (substring uri (match-beginning 2) (match-end 2)))

(defmacro jarchive--inhibit (op handler &rest body)
  "Run BODY with HANDLER inhibited for OP ."
  `(let ((inhibit-file-name-handlers (cons ,handler
                                           (and (eq inhibit-file-name-operation ,op)
                                                inhibit-file-name-handlers)))
         (inhibit-file-name-operation ,op))
     ,@body))

(defun jarchive--file-name-handler (op &rest args)
  "A `file-name-handler-alist' function for files matching `jarchive--url-regex'.
OP is an I/O primitive and ARGS are the remaining arguments passed to that primitive.
See `(elisp)Magic File Names'."
  (if-let ((uri (car args)))  ;; Sometimes this is invoked with nil args
      (let* ((_   (jarchive--match! uri))
             (jar-path (jarchive--match-jar uri))
             (file-path (jarchive--match-file uri)))
        (jarchive--inhibit op 'jarchive--file-name-handler
         (cond
          ((eq op 'expand-file-name) uri)
          ((eq op 'file-truename) uri)
          ((eq op 'file-name-directory) (file-name-directory jar-path))
          ((eq op 'file-name-nondirectory) (file-name-nondirectory file-path))
          ((eq op 'directory-file-name) (directory-file-name (file-name-directory jar-path)))
          ((eq op 'file-name-case-insensitive-p) (file-name-case-insensitive-p jar-path))
          ((eq op 'file-attributes) nil)

          ;; Predicates
          ((eq op 'file-directory-p) nil)
          ((eq op 'file-readable-p) (file-readable-p jar-path))
          ((eq op 'file-writable-p) nil)
          ((eq op 'file-exists-p) (file-exists-p jar-path))
          ((eq op 'file-remote-p) (file-remote-p jar-path))
          ((eq op 'file-symlink-p) (file-symlink-p jar-path))
          ((eq op 'file-accessible-directory-p) nil)
          ((eq op 'file-executable-p) nil)

          ;; Custom implementations
          ((eq op 'get-file-buffer)
           (seq-find (lambda (buf)
                       (string= uri (buffer-local-value 'buffer-file-name buf)))
                     (buffer-list)))
          ((eq op 'insert-file-contents) ;; This is executed in the context of a new buffer.
           (cl-destructuring-bind (_filename visit beg end replace) args
             (setq buffer-file-name uri)
             (when replace
               (erase-buffer))
             (archive-zip-extract jar-path file-path)
             (goto-char (point-min))
             (unless visit
               (set-buffer-modified-p nil)
               (when (or beg end)
                 (display-warning
                  'jarchive
                  "The beg and end options are not respected by the jarchive `insert-file-contents' handler."
                  :warning)))
             (setq buffer-offer-save nil)
             (rename-buffer (format "%s(%s)"
                                    (file-name-nondirectory file-path)
                                    (file-name-nondirectory jar-path))
                            t)
             (list uri (string-width (buffer-string)))))
          (t (apply op args)))))
    (jarchive--inhibit op 'jarchive--file-name-handler
                       (message "jarchive--inhibit %s for %s" op args)
                       (apply op args))))

(defun jarchive--find-file-not-found ()
  "Return t if the file not found was a file extracted by jarchive.
TODO: this might be unnecessary, try to remove"
  (and (string-match-p jarchive--uri-regex buffer-file-name)
       t))

(defun jarchive--wrap-legacy-eglot--path-to-uri (original-fn &rest args)
  "Hack until eglot is updated.
If path is a jar URI, don't parse. If it is not a jar call original impl."
  (let ((path (file-truename (car args))))
    (if (equal "jar" (url-type (url-generic-parse-url path)))
        path
      (apply 'funcall original-fn args))))

(defun jarchive--wrap-legacy-eglot--uri-to-path (original-fn &rest args)
  "Hack until eglot is updated.
If URI is a jar URI, don't parse and let the `jarchive--file-name-handler' handle it.
If it is not a jar call original impl."
  (let ((uri (car args)))
    (if (string= "file" (url-type (url-generic-parse-url uri)))
        (apply 'funcall original-fn args)
      uri)))

;;;###autoload
(defun jarchive-setup ()
  "setup jarchive, enabling emacs to open files inside jar archives.
the files can be identified with the `jar' uri scheme."
  (interactive)
  (with-eval-after-load 'eglot
    (when (version< emacs-version "29") ;; TODO, remove when eglot is updated in melpa
      (advice-add 'eglot--path-to-uri :around #'jarchive--wrap-legacy-eglot--path-to-uri)
      (advice-add 'eglot--uri-to-path :around #'jarchive--wrap-legacy-eglot--uri-to-path)))

  (add-to-list 'file-name-handler-alist (cons jarchive--uri-regex #'jarchive--file-name-handler))
  (add-to-list 'find-file-not-found-functions #'jarchive--find-file-not-found))

(provide 'jarchive)
;;; jarchive.el ends here
