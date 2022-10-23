;;; jarchive.el --- Enables navigation into jar archives -*- lexical-binding: t; -*-

;;; Commentary:
;; Jarchive extends Emacs to allow navigation into files contained withing .jar archives.

;;; Code:
(require 'arc-mode)

(defvar jarchive--hybrid-path-regex
  (rx
   ;; match group 1, the jar file location
   (group "/" (* not-newline) ".jar")
   ;; Potential delimiters between the jar and the file inside the jar
   (or "::" "!")
   ;; match the leading directory delimiter /,
   ;; archvie mode expects none so it's outside match group 2
   (zero-or-one "/")
   ;; match group 2, the file within the archive
   (group (* not-newline) "." (+ alphanumeric))
   line-end)
  "A regex for matching paths to a jar file and a file path into the jar file.
Delimited by `!' or `::'")

(defun jarchive--match-jar (hybrid-filename)
  (string-match jarchive--hybrid-path-regex hybrid-filename)
  (substring hybrid-filename (match-beginning 1) (match-end 1)))

(defun jarchive--match-file (hybrid-filename)
  (string-match jarchive--hybrid-path-regex hybrid-filename)
  (substring hybrid-filename (match-beginning 2) (match-end 2)))

(defvar-local jarchive--managed-buffer nil ;; consider making a minor mode
  "This value is t when a buffer is managed by jarchive.")

(defmacro jarchive--inhibit (op &rest body)
  "Run BODY with `jarchive--file-name-handler' inhibited for OP."
  `(let ((inhibit-file-name-handlers (cons (quote jarchive--file-name-handler)
                                           (and (eq inhibit-file-name-operation ,op)
                                                inhibit-file-name-handlers)))
         (inhibit-file-name-operation ,op))
     ,@body))

(defun jarchive--file-name-handler (op &rest args)
  "A `file-name-handler-alist' handler for opening files located in jars.
OP is a `(elisp)Magic File Names' operation and ARGS are any extra argument
provided when calling OP."
  (cond
   ((eq op 'get-file-buffer)
    (let* ((file  (car args))
           (jar (jarchive--match-jar file))
           (file-in-jar  (jarchive--match-file file))
           ;; Use a different filename that doesn't match `jarchive--hybrid-path-regex'
           ;; so that this handler will not deal with existing open buffers.
           (buffer-file (concat jar ":" file-in-jar)))
      (or (find-buffer-visiting buffer-file)
          (with-current-buffer (create-file-buffer buffer-file)
            (setq-local jarchive--managed-buffer t)
            (archive-zip-extract jar file-in-jar)
            (goto-char 0)
            (set-visited-file-name buffer-file)
            (setq-local default-directory (file-name-directory jar))
            (setq-local buffer-offer-save nil)
            (setq buffer-read-only t)
            (set-auto-mode)
            (set-buffer-modified-p nil)
            (current-buffer)))))
   (t (jarchive--inhibit op (apply op args)))))

;;;###autoload
(defun jarchive-setup ()
  (interactive)
  (add-to-list 'file-name-handler-alist (cons jarchive--hybrid-path-regex #'jarchive--file-name-handler)))

;; Temporary, for testing
(defmacro comment (&rest body) nil)
(comment
 (jarchive-setup)
 (defvar test-file "/home/user/.m2/repository/hiccup/hiccup/1.0.5/hiccup-1.0.5.jar!/hiccup/page.clj")
 (find-file test-file)
 )

(provide 'jarchive)
