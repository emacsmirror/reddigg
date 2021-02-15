;;; reddigg.el --- A reader for redditt -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Thanh Vuong

;; Author: Thanh Vuong <thanhvg@gmail.com>
;; URL: https://github.com/thanhvg/emacs-reddigg
;; Package-Requires: ((emacs "26.3") (promise "1.1") (ht "2.3") (request "0.3.0") (org "9.2"))
;; Version: 0.1

;; This program is free software; you can redistribute it and/or modify
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
;; TODO


;;; Code:

(require 'promise)
(require 'request)
(require 'cl-lib)
(require 'ht)
(require 'org)
(require 'json)
(require 'url-util)
;; (require 'subr-x)

(defgroup reddigg nil
  "Search and read stackoverflow and sisters's sites."
  :group 'extensions
  :group 'convenience
  :version "26.1"
  :link '(emacs-commentary-link "reddigg.el"))

(defcustom reddigg-subs '(acmilan emacs starcraft)
  "List of subreddits."
  :type 'list
  :group 'reddigg)

(defun reddigg--parse-json-buffer ()
  "Read json from buffer."
  (if (fboundp 'json-parse-buffer)
      (json-parse-buffer
       :object-type 'hash-table
       :null-object nil
       :false-object nil)
    (let ((json-array-type 'vector)
          (json-object-type 'hash-table)
          (json-false nil))
      (json-read))))

(defconst reddigg--sub-url
  "https://www.reddit.com/r/%s.json?count=25"
  "Sub reddit template.")

(defconst reddigg--cmt-url
  "https://www.reddit.com/%s.json"
  "Comment link template.")

(defvar reddigg--template-sub "[[elisp:(reddigg-view-sub \"%s\")][%s]]\n"
  "Template string for main.")

(defun reddigg--ensure-modes ()
  "Get a bunch of modes up and running."
  (if (equal major-mode 'org-mode)
      (org-set-startup-visibility)
    (org-mode)
    (font-lock-flush))
  (visual-line-mode))

(cl-defun reddigg--promise-posts (sub &key after before)
  "Promise SUB post list with keyword AFTER and BEFORE."
  (reddigg--promise-json
   (concat
    (format reddigg--sub-url sub)
    (when after
      (concat "&after=" after))
    (when before
      (concat "&before=" before)))))

(defun reddigg--promise-comments (cmt)
  "Promise CMT list."
  (reddigg--promise-json (format reddigg--cmt-url cmt)))

(defun reddigg--promise-json (url)
  "Promise a json from URL."
  (promise-new
   (lambda (resolve reject)
     (request (url-encode-url url)
       :headers `(("User-Agent" . "emacs"))
       :parser 'reddigg--parse-json-buffer
       ;; :parser 'json-read
       :error (cl-function (lambda (&rest args &key error-thrown &allow-other-keys)
                             (funcall reject  error-thrown)))
       :success (cl-function (lambda (&key data &allow-other-keys)
                               (message "got result")
                               (funcall resolve data)))))))

(defvar reddigg--main-buffer "*reddigg-main*"
  "Buffer for main page.")

(defvar reddigg--buffer "*reddigg*"
  "Buffer for main page.")

(defvar reddigg--cmt-buffer "*reddigg-comments*"
  "Comment buffer.")

(defun reddigg--get-buffer ()
  "Get buffer for sub."
  (get-buffer-create reddigg--buffer))

(defun reddigg--get-cmt-buffer ()
  "Get buffer for comments."
  (get-buffer-create reddigg--cmt-buffer))

(defun reddigg--get-main-buffer ()
  "Get main buffer."
  (get-buffer-create reddigg--main-buffer))

(defun reddigg--print-sub (data sub &optional append)
  "Print sub post list in DATA for SUB.
When APPEND is non-nil, will not delete buffer but append to it,
after deleting the current line which should be the More button."
  (with-current-buffer (reddigg--get-buffer)
    (save-excursion
      (if append
          (kill-whole-line)
        (erase-buffer)
        (insert "#+startup: overview indent\n")
        (insert "#+title: posts\n")
        (insert (format reddigg--template-sub sub "refresh")))

      (seq-do
       (lambda (it)
         (let ((my-it (gethash "data" it)))
           (insert "* " (gethash "title" my-it) "\n")
           (insert "| " (ht-get my-it "subreddit_name_prefixed") " | ")
           (insert "score: " (format "%s" (gethash "score" my-it) ) " | ")
           (insert "comments: " (format "%s" (gethash "num_comments" my-it)) " |\n")
           (let ((selftext (gethash "selftext" my-it)) begin end)
             (if (string-empty-p selftext)
                 (insert (format "%s \n[[eww:%s][view in eww]]\n"
                                 (gethash "url" my-it) (gethash "url" my-it)))
               (setq begin (point))
               (insert "\n" selftext "\n")
               (setq end (point))
               (reddigg--sanitize-range begin end)))
           (insert (format "[[elisp:(reddigg--view-comments \"%s\")][view comments]]\n"
                           (ht-get my-it "permalink")))))
       (ht-get data "children"))
      (let ((after (ht-get data "after")))
        (when after
          (insert (format "* [[elisp:(reddigg--view-sub-more \"%s\" \"%s\")][More]]" sub after))))
      (reddigg--ensure-modes))))

(defun reddigg--sanitize-range (begin end)
  "Remove heading * inside rang between BEGIN and END."
  (save-excursion
    (goto-char begin)
    (while (re-search-forward "^\\* " end t)
      (replace-match "- "))))

(defun reddigg--print-comment-list (cmt-list level)
  "Print comments from CMT-LIST with LEVEL."
  (seq-do
   (lambda (it)
     (let* ((kind (ht-get it "kind"))
            (data (ht-get it "data"))
            (replies (ht-get data "replies"))
            begin end)
       (if (string= kind "more")
           (insert level " reddigg: too many subcomments\n")
         (insert level " " (ht-get data "author") "\n")
         (setq begin (point))
         (insert (ht-get data "body") "\n")
         (setq end (point))
         (reddigg--sanitize-range begin end)
         (when (hash-table-p replies)
           (reddigg--print-comment-list (ht-get* replies "data" "children") (concat level "*"))))))
   cmt-list))

(defun reddigg--print-comment-1 (data)
  "Print the post content from DATA."
  (let ((cmt (ht-get* (aref (ht-get* data "data" "children") 0) "data")) begin end)
    (insert (ht-get cmt "url") "\n")
    (insert "author: " (ht-get cmt "author") "\n")
    (insert (format "[[elisp:(reddigg--view-comments \"%s\" t)][refresh]]\n"
                    (ht-get cmt "permalink")))
    (setq begin (point))
    (insert (gethash "selftext" cmt) "\n")
    (setq end (point))
    (reddigg--sanitize-range begin end)))

(defun reddigg--print-comment-2 (data level)
  "Extrac comment list from DATA and pass it along with LEVEL."
  (reddigg--print-comment-list (ht-get* data "data" "children") level))

(defun reddigg--print-comments (data)
  "Print comments DATA to buffer."
  (with-current-buffer (reddigg--get-cmt-buffer)
    (erase-buffer)
    (insert "#+startup: overview indent\n")
    (insert "#+title: comments\n")
    (reddigg--print-comment-1 (aref data 0))
    (reddigg--print-comment-2 (aref data 1) "*")
    (reddigg--ensure-modes)))

(defun reddigg-view-comments (cmt)
  "Ask and print CMT to buffer."
  (interactive "sComent: ")
  (reddigg--view-comments cmt))

(defun reddigg--view-comments (cmt &optional new-window)
  "Ask and print CMT to buffer. When NEW-WINDOW will show in new buffer."
  (promise-chain (reddigg--promise-comments cmt)
    (then #'reddigg--print-comments)
    (then (lambda (&rest _)
            (if new-window
                (switch-to-buffer (reddigg--get-cmt-buffer))
              (select-window
               (display-buffer
                (reddigg--get-cmt-buffer)
                '(display-buffer-use-some-window (inhibit-same-window . t)))))))
    (promise-catch (lambda (reason)
                     (message "catch error in promise: %s" reason)))))


(cl-defun reddigg--view-sub (sub &key after before append)
  "Fetch SUB and print its post list.
AFTER: fetch post after name.
BEFORE: fetch posts before name
APPEND: tell `reddigg--print-sub' to append."
  (promise-chain (reddigg--promise-posts sub :after after :before before)
    (then (lambda (result)
            (ht-get result "data")))
    (then (lambda (data)
            (reddigg--print-sub data sub append)))
    (then (lambda (&rest _)
            (switch-to-buffer (reddigg--get-buffer))))
    (promise-catch (lambda (reason)
                     (message "catch error in promise: %s" reason)))))

(defun reddigg-view-sub (sub)
  "Prompt SUB and print its post list."
  (interactive "sSubreddit: ")
  (reddigg--view-sub sub))

(defun reddigg--view-sub-more (sub after)
  "Fetch SUB from AFTER and appen."
  (reddigg--view-sub sub :after after :append t))

(defun reddigg-view-main ()
  "View main page."
  (interactive)
  (with-current-buffer (reddigg--get-main-buffer)
    (erase-buffer)
    (insert "#+startup: overview indent\n")
    (insert "#+title: main\n\n")
    (insert (format reddigg--template-sub "all" "all"))
    (insert (format reddigg--template-sub "popular" "popular"))
    (insert (format reddigg--template-sub (mapconcat #'symbol-name reddigg-subs "+") "main"))
    (dolist (sub reddigg-subs)
      (insert (format reddigg--template-sub sub sub)))
    (reddigg--ensure-modes))
  (switch-to-buffer (reddigg--get-main-buffer)))

(provide 'reddigg)
;;; reddigg.el ends here