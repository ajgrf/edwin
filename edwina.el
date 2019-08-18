;;; edwina.el --- Dynamic window manager -*- lexical-binding: t -*-

;; Author: Alex Griffin <a@ajgrf.com>
;; URL: https://github.com/ajgrf/edwina
;; Version: 0.1.2-pre
;; Package-Requires: ((emacs "25"))

;;; Copyright © 2019 Alex Griffin <a@ajgrf.com>
;;;
;;;
;;; This file is NOT part of GNU Emacs.
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Edwina is a dynamic window manager for Emacs. It automatically arranges your
;; Emacs panes (called "windows" in Emacs parlance) into predefined layouts,
;; dwm-style.

;;; Code:

(require 'seq)

(defvar edwina-layout 'edwina-tall-layout
  "The current Edwina layout.
A layout is a function that takes a list of panes, and arranges them into
a window configuration.")

(defvar edwina-nmaster 1
  "The number of windows to put in the Edwina master area.")

(defvar edwina-mfact 0.55
  "The size of the master area in proportion to the stack area.")

(defvar edwina--window-fields
  '(buffer start hscroll vscroll point prev-buffers)
  "List of window fields to save and restore.")

(defvar edwina--window-params
  '(delete-window quit-restore)
  "List of window parameters to save and restore.")

(defun edwina-pane (window)
  "Create pane from WINDOW.
A pane is Edwina's internal window abstraction, an association list containing
a buffer and other information."
  (let ((pane '()))
    (dolist (field edwina--window-fields)
      (let* ((getter (intern (concat "window-" (symbol-name field))))
             (value (funcall getter window)))
        (push (cons field value) pane)))
    (dolist (param edwina--window-params)
      (let ((value (window-parameter window param)))
        (push (cons param value) pane)))
    pane))

(defun edwina-restore-pane (pane)
  "Restore PANE in the selected window."
  (dolist (field edwina--window-fields)
    (let ((setter (intern (concat "set-window-" (symbol-name field))))
          (value  (alist-get field pane)))
      (funcall setter nil value)))
  (dolist (param edwina--window-params)
    (set-window-parameter nil param (alist-get param pane)))
  (unless (window-parameter nil 'delete-window)
    (set-window-parameter nil 'delete-window #'edwina-delete-window)))

(defun edwina--window-list (&optional frame)
  "Return a list of windows on FRAME in layout order."
  (window-list frame nil (frame-first-window frame)))

(defun edwina-pane-list (&optional frame)
  "Return the current list of panes on FRAME in layout order."
  (mapcar #'edwina-pane (edwina--window-list frame)))

(defmacro edwina--respective-window (window &rest body)
  "Execute Edwina manipulations in BODY and return the respective WINDOW."
  (declare (indent 1))
  `(let* ((window ,window)
          (windows (edwina--window-list))
          (index (seq-position windows window)))
     ,@body
     (nth index (edwina--window-list))))

(defun edwina-arrange (&optional panes)
  "Arrange PANES according to Edwina's current layout."
  (interactive)
  (let* ((panes (or panes (edwina-pane-list))))
    (select-window
     (edwina--respective-window (selected-window)
       (delete-other-windows)
       (funcall edwina-layout panes)))))

(defun edwina--display-buffer (display-buffer &rest args)
  "Apply DISPLAY-BUFFER to ARGS and arrange windows.
Meant to be used as advice :around `display-buffer'."
  (edwina--respective-window (apply display-buffer args)
    (edwina-arrange)))

(defun edwina-stack-layout (panes)
  "Edwina layout that stacks PANES evenly on top of each other."
  (let ((split-height (ceiling (/ (window-height)
                                  (length panes)))))
    (edwina-restore-pane (car panes))
    (dolist (pane (cdr panes))
      (select-window
       (split-window nil split-height 'below))
      (edwina-restore-pane pane))))

(defun edwina--mastered (side layout)
  "Add a master area to LAYOUT.
SIDE has the same meaning as in `split-window', but putting master to the
right or bottom is not supported."
  (lambda (panes)
    (let ((master (seq-take panes edwina-nmaster))
          (stack  (seq-drop panes edwina-nmaster))
          (msize  (ceiling (* -1
                              edwina-mfact
                              (if (memq side '(left right t))
                                  (frame-width)
                                (frame-height))))))
      (when stack
        (funcall layout stack))
      (when master
        (when stack
          (select-window
           (split-window (frame-root-window) msize side)))
        (edwina-stack-layout master)))))

(defvar edwina-narrow-threshold 132
  "Put master area on top if the frame is narrower than this.")

(defun edwina-tall-layout (panes)
  "Edwina layout with master and stack areas for PANES."
  (let* ((side (if (< (frame-width) edwina-narrow-threshold) 'above 'left))
         (layout (edwina--mastered side #'edwina-stack-layout)))
    (funcall layout panes)))

(defun edwina-select-next-window ()
  "Move cursor to the next window in cyclic order."
  (interactive)
  (select-window (next-window)))

(defun edwina-select-previous-window ()
  "Move cursor to the previous window in cyclic order."
  (interactive)
  (select-window (previous-window)))

(defun edwina-swap-next-window ()
  "Swap the selected window with the next window."
  (interactive)
  (window-swap-states (selected-window)
                      (next-window)))

(defun edwina-swap-previous-window ()
  "Swap the selected window with the previous window."
  (interactive)
  (window-swap-states (selected-window)
                      (previous-window)))

(defun edwina-dec-mfact ()
  "Decrease the size of the master area."
  (interactive)
  (setq edwina-mfact (max (- edwina-mfact 0.05)
                         0.05))
  (edwina-arrange))

(defun edwina-inc-mfact ()
  "Increase the size of the master area."
  (interactive)
  (setq edwina-mfact (min (+ edwina-mfact 0.05)
                         0.95))
  (edwina-arrange))

(defun edwina-dec-nmaster ()
  "Decrease the number of windows in the master area."
  (interactive)
  (setq edwina-nmaster (- edwina-nmaster 1))
  (when (< edwina-nmaster 0)
    (setq edwina-nmaster 0))
  (edwina-arrange))

(defun edwina-inc-nmaster ()
  "Increase the number of windows in the master area."
  (interactive)
  (setq edwina-nmaster (+ edwina-nmaster 1))
  (edwina-arrange))

(defun edwina-clone-window ()
  "Clone selected window."
  (interactive)
  (split-window-below)
  (edwina-arrange))

(defun edwina-delete-window (&optional window)
  "Delete WINDOW."
  (interactive)
  (let ((ignore-window-parameters t))
    (delete-window window)
    (edwina-arrange)))

(defun edwina-zoom ()
  "Zoom/cycle the selected window to/from master area."
  (interactive)
  (if (eq (selected-window) (frame-first-window))
      (edwina-swap-next-window)
    (let ((pane (edwina-pane (selected-window))))
      (edwina-delete-window)
      (edwina-arrange (cons pane (edwina-pane-list))))))

(defvar edwina-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-r") 'edwina-arrange)
    (define-key map (kbd "M-j") 'edwina-select-next-window)
    (define-key map (kbd "M-k") 'edwina-select-previous-window)
    (define-key map (kbd "M-J") 'edwina-swap-next-window)
    (define-key map (kbd "M-K") 'edwina-swap-previous-window)
    (define-key map (kbd "M-h") 'edwina-dec-mfact)
    (define-key map (kbd "M-l") 'edwina-inc-mfact)
    (define-key map (kbd "M-d") 'edwina-dec-nmaster)
    (define-key map (kbd "M-i") 'edwina-inc-nmaster)
    (define-key map (kbd "M-C") 'edwina-delete-window)
    (define-key map (kbd "M-<return>") 'edwina-zoom)
    (define-key map (kbd "M-S-<return>") 'edwina-clone-window)
    map)
  "Keymap for command `edwina-mode'.")

(defvar edwina-mode-map-alist
  `((edwina-mode . ,edwina-mode-map))
  "Add to `emulation-mode-map-alists' to give bindings higher precedence.")

(defun edwina--init ()
  "Initialize command `edwina-mode'."
  (add-to-list 'emulation-mode-map-alists
               'edwina-mode-map-alist)
  (advice-add #'display-buffer :around #'edwina--display-buffer)
  (edwina-arrange))

(defun edwina--clean-up ()
  "Clean up when disabling command `edwina-mode'."
  (advice-remove #'display-buffer #'edwina--display-buffer))

;;;###autoload
(define-minor-mode edwina-mode
  "Toggle Edwina mode on or off.
With a prefix argument ARG, enable Edwina mode if ARG is
positive, and disable it otherwise.  If called from Lisp, enable
the mode if ARG is omitted or nil, and toggle it if ARG is `toggle'.

Edwina mode is a global minor mode that provides dwm-like dynamic
window management for Emacs windows."
  :global t
  :lighter " edwina"
  (if edwina-mode
      (edwina--init)
    (edwina--clean-up)))

(provide 'edwina)
;;; edwina.el ends here
