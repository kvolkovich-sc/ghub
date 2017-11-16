;;; ghub.el --- minuscule client for the Github API  -*- lexical-binding: t -*-

;; Copyright (C) 2016-2017  Jonas Bernoulli

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Homepage: https://github.com/magit/ghub
;; Keywords: tools
;; Package-Requires: ((emacs "24.4"))

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a copy of the GPL see https://www.gnu.org/licenses/gpl.txt.

;;; Commentary:

;; This library provides basic support for accessing the Github
;; API from Emacs packages.  For more information see the wiki,
;; which can be found at https://github.com/magit/ghub/wiki.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'json)
(require 'url)
(require 'url-auth)

(eval-when-compile (require 'subr-x))

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

;;; Settings

(defvar ghub-default-host "api.github.com")
(defvar ghub-github-token-scopes '(repo))
(defvar ghub-override-system-name nil)

;;; Request
;;;; API

(defvar ghub-response-headers nil)

(defun ghub-get (resource &optional params data headers unpaginate
                          noerror reader username auth host)
  "Make a `GET' request for RESOURCE, optionally sending PARAMS and/or DATA.
Like calling `ghub-request' (which see) with \"GET\" as METHOD."
  (ghub-request "GET" resource params data headers unpaginate
                noerror reader username auth host))

(defun ghub-put (resource &optional params data headers unpaginate
                          noerror reader username auth host)
  "Make a `PUT' request for RESOURCE, optionally sending PARAMS and/or DATA.
Like calling `ghub-request' (which see) with \"PUT\" as METHOD."
  (ghub-request "PUT" resource params data headers unpaginate
                noerror reader username auth host))

(defun ghub-head (resource &optional params data headers unpaginate
                           noerror reader username auth host)
  "Make a `HEAD' request for RESOURCE, optionally sending PARAMS and/or DATA.
Like calling `ghub-request' (which see) with \"HEAD\" as METHOD."
  (ghub-request "HEAD" resource params data headers unpaginate
                noerror reader username auth host))

(defun ghub-post (resource &optional params data headers unpaginate
                           noerror reader username auth host)
  "Make a `POST' request for RESOURCE, optionally sending PARAMS and/or DATA.
Like calling `ghub-request' (which see) with \"POST\" as METHOD."
  (ghub-request "POST" resource params data headers unpaginate
                noerror reader username auth host))

(defun ghub-patch (resource &optional params data headers unpaginate
                            noerror reader username auth host)
  "Make a `PATCH' request for RESOURCE, optionally sending PARAMS and/or DATA.
Like calling `ghub-request' (which see) with \"PATCH\" as METHOD."
  (ghub-request "PATCH" resource params data headers unpaginate
                noerror reader username auth host))

(defun ghub-delete (resource &optional params data headers unpaginate
                             noerror reader username auth host)
  "Make a `DELETE' request for RESOURCE, optionally sending PARAMS and/or DATA.
Like calling `ghub-request' (which see) with \"DELETE\" as METHOD."
  (ghub-request "DELETE" resource params data headers unpaginate
                noerror reader username auth host))

(define-error 'ghub-error "Ghub Error")
(define-error 'ghub-http-error "HTTP Error" 'ghub-error)
(define-error 'ghub-301 "Moved Permanently" 'ghub-http-error)
(define-error 'ghub-400 "Bad Request" 'ghub-http-error)
(define-error 'ghub-401 "Unauthorized" 'ghub-http-error)
(define-error 'ghub-403 "Forbidden" 'ghub-http-error)
(define-error 'ghub-404 "Not Found" 'ghub-http-error)
(define-error 'ghub-422 "Unprocessable Entity" 'ghub-http-error)

(defun ghub-request (method resource &optional params data headers unpaginate
                            noerror reader username auth host)
  "Make a request for RESOURCE using METHOD."
  (unless host
    (setq host ghub-default-host))
  (let* ((p (and params (concat "?" (ghub--url-encode-params params))))
         (d (and data   (encode-coding-string (json-encode-list data) 'utf-8)))
         (buf (let ((url-request-extra-headers
                     `(("Content-Type" . "application/json")
                       ,@(and (not (eq auth 'none))
                              (list (cons "Authorization"
                                          (ghub--auth host auth username))))
                       ,@headers))
                    (url-request-method method)
                    (url-request-data d))
                (url-retrieve-synchronously
                 (concat "https://" host resource p)))))
    (unwind-protect
        (with-current-buffer buf
          (set-buffer-multibyte t)
          (let (link body)
            (goto-char (point-min))
            (let (headers)
              (while (re-search-forward "^\\([^:]*\\): \\(.+\\)"
                                        url-http-end-of-headers t)
                (push (cons (match-string 1)
                            (match-string 2))
                      headers))
              (and (setq link (cdr (assoc "Link" headers)))
                   (setq link (car (rassoc
                                    (list "rel=\"next\"")
                                    (mapcar (lambda (elt) (split-string elt "; "))
                                            (split-string link ",")))))
                   (string-match "[?&]page=\\([^&>]+\\)" link)
                   (setq link (match-string 1 link)))
              (setq ghub-response-headers (nreverse headers)))
            (unless url-http-end-of-headers
              (error "ghub: url-http-end-of-headers is nil when it shouldn't"))
            (goto-char (1+ url-http-end-of-headers))
            (setq body (funcall (or reader 'ghub--read-json-response)))
            (unless (or noerror (= (/ url-http-response-status 100) 2))
              (let ((data (list method resource p d body)))
                (pcase url-http-response-status
                  (301 (signal 'ghub-301 data))
                  (400 (signal 'ghub-400 data))
                  (401 (signal 'ghub-401 data))
                  (403 (signal 'ghub-403 data))
                  (404 (signal 'ghub-404 data))
                  (422 (signal 'ghub-422 data))
                  (_   (signal 'ghub-http-error
                               (cons url-http-response-status data))))))
            (if (and link unpaginate)
                (nconc body
                       (ghub-request method resource
                                     (cons (cons 'page link)
                                           (cl-delete 'page params :key #'car))
                                     data headers t noerror
                                     reader username auth host))
              body)))
      (kill-buffer buf))))

(defun ghub-wait (resource &optional username auth host)
  "Busy-wait until RESOURCE becomes available."
  (with-local-quit
    (let ((for 0.5)
          (total 0))
      (while (not (ignore-errors (ghub-get resource nil nil nil nil nil nil
                                           username auth host)))
        (setq for (truncate (* 2 for)))
        (setq total (+ total for))
        (when (= for 128)
          (signal 'ghub-error
                  (list (format "Github is taking too long to create %s"
                                resource))))
        (message "Waiting for %s (%ss)..." resource total)
        (sit-for for)))))

;;;; Internal

(defun ghub--read-json-response ()
  (and (not (eobp))
       (let ((json-object-type 'alist)
             (json-array-type  'list)
             (json-key-type    'symbol)
             (json-false       nil)
             (json-null        nil))
         (json-read-from-string (ghub--read-raw-response)))))

(defun ghub--read-raw-response ()
  (and (not (eobp))
       (decode-coding-string
        (buffer-substring-no-properties (point) (point-max))
        'utf-8)))

(defun ghub--url-encode-params (params)
  (mapconcat (lambda (param)
               (concat (url-hexify-string (symbol-name (car param))) "="
                       (url-hexify-string (cdr param))))
             params "&"))

;;; Authentication
;;;; API

(defun ghub-create-token (host username package scopes)
  (interactive
   (let ((host (read-string "Host: " ghub-default-host)))
     (list host
           (read-string "Username: " (ghub--username host))
           (intern (read-string "Package: " "ghub"))
           (split-string (read-string "Scopes (separated by commas): ")
                         "," t t))))
  (let ((user (ghub--ident username package)))
    (cl-destructuring-bind (_save token)
        (ghub--auth-source-get (list :save-function :secret)
          :create t :host host :user user
          :secret
          (cdr (assq 'token
                     (ghub-post
                      "/authorizations" nil
                      `((scopes . ,scopes)
                        (note   . ,(ghub--ident-github package)))
                      nil nil nil nil username 'basic host))))
      ;; If the Auth-Source cache contains the information that there
      ;; is no value, then setting the value does not invalidate that
      ;; now incorrect information.
      (auth-source-forget (list :host host :user user))
      token)))

;;;; Internal

(defun ghub--auth (host auth &optional username)
  (unless username
    (setq username (ghub--username host)))
  (encode-coding-string
   (if (eq auth 'basic)
       (ghub--basic-auth host username)
     (concat "token "
             (cond ((stringp auth) auth)
                   ((null    auth) (ghub--token host username 'ghub))
                   ((symbolp auth) (ghub--token host username auth))
                   (t (signal 'wrong-type-argument
                              `((or stringp symbolp) ,auth))))))
   'utf-8))

(defun ghub--basic-auth (host username)
  (let ((url (url-generic-parse-url (concat "https://" host))))
    (setf (url-user url) username)
    (url-basic-auth url t)))

(defun ghub--token (host username package &optional nocreate)
  (let ((user (ghub--ident username package)))
    (or (ghub--auth-source-get :secret :host host :user user)
        (progn
          ;; Auth-Source caches the information that there is no
          ;; value, but in our case that is a situation that needs
          ;; fixing so we want to keep trying by invalidating that
          ;; information.
          (auth-source-forget (list :host host :user user))
          (and (not nocreate)
               (ghub--confirm-create-token host username package))))))

(defun ghub--username (host)
  (let ((var (if (string-prefix-p "api.github.com" host)
                 "github.user"
               (format "github.%s.user" host))))
    (condition-case nil
        (car (process-lines "git" "config" var))
      (error
       (let ((user (read-string
                    (format "Git variable `%s' is unset.  Set to: " var))))
         (or (and user (progn (call-process "git" nil nil nil
                                            "config" "--global" var user)
                              user))
             (user-error "Abort")))))))

(defun ghub--ident (username package)
  (format "%s^%s" username package))

(defun ghub--ident-github (package)
  (format "Emacs package %s @ %s"
          package
          (or ghub-override-system-name (system-name))))

(defun ghub--package-scopes (package)
  (symbol-value (intern (format "%s-github-token-scopes" package))))

(defun ghub--confirm-create-token (host username package)
  (let* ((id-str (ghub--ident-github package))
         (id-nbr (ghub--get-token-id host username package))
         (scopes (ghub--package-scopes package))
         (max-mini-window-height 40))
    (if (yes-or-no-p
         (format
          "Such a Github API token is not available:

  Url:     %s
  User:    %s
  Package: %s

  Scopes requested in `%s-github-token-scopes':\n%s
  Store locally according to `auth-source':\n    %S
  Store on Github as:\n    %S
%s
WARNING: If you have enabled two-factor authentication
         then you have to create the token manually.

If in doubt, then abort and view the documentation first.

Create and store such a token? "
          host username package package
          (mapconcat (lambda (scope) (format "    %s" scope)) scopes "\n")
          auth-sources id-str
          (if id-nbr
              "
WARNING: A matching token exists but is unavailable.
         It will be replaced.\n"
            "")))
        (progn
          (when id-nbr
            (ghub--delete-token host username package))
          (ghub-create-token host username package scopes))
      (user-error "Abort"))))

(defun ghub--get-token-id (host username package)
  (let ((ident (ghub--ident-github package)))
    (cl-some (lambda (x)
               (let-alist x
                 (and (equal .app.name ident) .id)))
             (ghub-get "/authorizations" nil nil nil t nil nil
                       username 'basic host))))

(defun ghub--get-token-plist (host username package)
  (ghub-get (format "/authorizations/%s"
                    (ghub--get-token-id host username package))
            nil nil nil nil nil nil username 'basic host))

(defun ghub--delete-token (host username package)
  (ghub-delete (format "/authorizations/%s"
                       (ghub--get-token-id host username package))
               nil nil nil nil nil nil username 'basic host))

(defun ghub--auth-source-get (key:s &rest spec)
  (declare (indent 1))
  (let ((plist (car (apply #'auth-source-search :max 1 spec))))
    (cl-flet ((value (k) (let ((v (plist-get plist k)))
                           (if (functionp v) (funcall v) v))))
      (if (listp key:s)
          (mapcar #'value key:s)
        (value key:s)))))

;;; ghub.el ends soon
(provide 'ghub)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; ghub.el ends here
