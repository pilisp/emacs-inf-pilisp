;;; inf-pilisp.el --- Run an external PiLisp process in an Emacs buffer -*- lexical-binding: t; -*-

;; Copyright © 2023 Daniel Gregoire

;; Port of inf-clojure for PiLisp use. Copyrights and licenses of that project
;; in effect as applicable.

;; Authors: Daniel <daniel.l.gregoire@gmail.com>
;; Maintainer: Daniel Gregoire <daniel.l.gregoire@gmail.com>
;; URL: http://github.com/pilisp/emacs-inf-pilisp
;; Keywords: processes, comint, pilisp, clojure
;; Version: 3.2.1
;; Package-Requires: ((emacs "25.1") (pilisp-mode "5.11"))

;; This file is not part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This package provides basic interaction with a PiLisp subprocess (REPL).
;; It's based on ideas from the popular `inferior-lisp` package.
;;
;; `inf-pilisp` has two components - a PiLisp REPL and a minor mode
;; (`inf-pilisp-minor-mode`), which extends `pilisp-mode` with
;; commands to evaluate forms directly in the REPL.
;;
;; `inf-pilisp` provides a set of essential features for interactive
;; PiLisp:
;;
;; * REPL
;; * Interactive code evaluation
;; * Code completion
;; * Definition lookup
;; * Documentation lookup
;; * ElDoc
;; * Apropos
;; * Macroexpansion
;;
;; If you're installing manually, you'll need to:
;;
;; * drop the file somewhere on your load path (perhaps ~/.emacs.d)
;; * Add the following lines to your .emacs file:
;;
;;    (autoload 'inf-pilisp "inf-pilisp" "Run an inferior PiLisp process" t)
;;    (add-hook 'pilisp-mode-hook #'inf-pilisp-minor-mode)

;;; Code:

(require 'comint)
(require 'clojure-mode)
(require 'pilisp-mode)
(require 'eldoc)
(require 'thingatpt)
(require 'ansi-color)
(require 'cl-lib)
(require 'subr-x)

(defvar inf-pilisp-startup-forms '((pilisp . "pl")))

(defvar inf-pilisp-repl-features
  '((pilisp . ((load . "(repl/load-file %s)")
               (doc . "(doc %s)")
               (arglists . "(arglists %s)")
               (macroexpand . "(macroexpand '%s)")
               (macroexpand-1 . "(macroexpand-1 '%s)")
               (completion . "(repl/completions \"%s\")")))))

(defvar-local inf-pilisp-repl-type 'pilisp
  "Symbol to define your REPL type.
Its root binding is nil and it can be further customized using
either `setq-local` or an entry in `.dir-locals.el`." )

(defvar inf-pilisp-buffer nil
  "The current `inf-pilisp' process buffer.

MULTIPLE PROCESS SUPPORT
===========================================================================
To run multiple PiLisp processes, you start the first up
with \\[inf-pilisp].  It will be in a buffer named `*inf-pilisp*'.
Rename this buffer with \\[rename-buffer].  You may now start up a new
process with another \\[inf-pilisp].  It will be in a new buffer,
named `*inf-pilisp*'.  You can switch between the different process
buffers with \\[switch-to-buffer].

Commands that send text from source buffers to PiLisp processes --
like `inf-pilisp-eval-defun' or `inf-pilisp-show-arglists' -- have to choose a
process to send to, when you have more than one PiLisp process around.  This
is determined by the global variable `inf-pilisp-buffer'.  Suppose you
have three inferior PiLisps running:
    Buffer              Process
    foo                 inf-pilisp
    bar                 inf-pilisp<2>
    *inf-pilisp*     inf-pilisp<3>
If you do a \\[inf-pilisp-eval-defun] command on some PiLisp source code,
what process do you send it to?

- If you're in a process buffer (foo, bar, or *inf-pilisp*),
  you send it to that process.
- If you're in some other buffer (e.g., a source file), you
  send it to the process attached to buffer `inf-pilisp-buffer'.
This process selection is performed by function `inf-pilisp-proc'.

Whenever \\[inf-pilisp] fires up a new process, it resets
`inf-pilisp-buffer' to be the new process's buffer.  If you only run
one process, this does the right thing.  If you run multiple
processes, you might need to change `inf-pilisp-buffer' to
whichever process buffer you want to use.")

(defun inf-pilisp--get-feature (repl-type feature no-error)
  "Get FEATURE for REPL-TYPE from repl-features.
If no-error is truthy don't error if feature is not present."
  (let ((feature-form (alist-get feature (alist-get repl-type inf-pilisp-repl-features))))
    (cond (feature-form feature-form)
          (no-error nil)
          (t (error "%s not configured for %s" feature repl-type)))))

(defun inf-pilisp-get-feature (proc feature &optional no-error)
  "Get FEATURE based on repl type for PROC."
  (let* ((repl-type (or (with-current-buffer (process-buffer proc)
                          inf-pilisp-repl-type)
                        'pilisp
                        (error "REPL type is not known"))))
    (inf-pilisp--get-feature repl-type feature no-error)))

(defun inf-pilisp--update-feature (repl-type feature form)
  "Return a copy of the datastructure containing the repl features.
Given a REPL-TYPE (`pilisp', `lumo', ...) and a FEATURE (`doc',
`apropos', ...) and a FORM this will return a new datastructure
that can be set as `inf-pilisp-repl-features'."
  (let ((original (alist-get repl-type inf-pilisp-repl-features)))
    (if original
        (cons (cons repl-type (cons (cons feature form) (assoc-delete-all feature original)))
              (assoc-delete-all repl-type inf-pilisp-repl-features))
      (error "Attempted to update %s form of unknown REPL type %s"
             (symbol-name feature)
             (symbol-name repl-type)))))

(defun inf-pilisp-update-feature (repl-type feature form)
  "Mutate the repl features to the new FORM.
Given a REPL-TYPE (`pilisp', `lumo', ...) and a FEATURE (`doc',
`apropos', ...) and a FORM this will set
`inf-pilisp-repl-features' with these new values."
  (setq inf-pilisp-repl-features (inf-pilisp--update-feature repl-type feature form)))

(defun inf-pilisp-proc (&optional no-error)
  "Return the current inferior PiLisp process.
When NO-ERROR is non-nil, don't throw an error when no process
has been found.  See also variable `inf-pilisp-buffer'."
  (or (get-buffer-process (if (derived-mode-p 'inf-pilisp-mode)
                              (current-buffer)
                            inf-pilisp-buffer))
      (unless no-error
        (error "No PiLisp subprocess; see variable `inf-pilisp-buffer'"))))

(defun inf-pilisp-repl-p (&optional buf)
  "Indicates if BUF is an inf-pilisp REPL.
If BUF is nil then defaults to the current buffer.
Checks the mode and that there is a live process."
  (let ((buf (or buf (current-buffer))))
    (and (with-current-buffer buf (derived-mode-p 'inf-pilisp-mode))
         (get-buffer-process buf)
         (process-live-p (get-buffer-process buf)))))

(defun inf-pilisp-repls ()
  "Return a list of all inf-pilisp REPL buffers."
  (let (repl-buffers)
    (dolist (b (buffer-list))
      (when (inf-pilisp-repl-p b)
        (push (buffer-name b) repl-buffers)))
    repl-buffers))

(defun inf-pilisp--prompt-repl-buffer (prompt)
  "Prompt the user to select an inf-pilisp repl buffer.
PROMPT is a string to prompt the user.
Returns nil when no buffer is selected."
  (let ((repl-buffers (inf-pilisp-repls)))
    (if (> (length repl-buffers) 0)
        (when-let ((repl-buffer (completing-read prompt repl-buffers nil t)))
          (get-buffer repl-buffer))
      (user-error "No buffers have an inf-pilisp process"))))

(defun inf-pilisp-set-repl (always-ask)
  "Set an inf-pilisp buffer as the active (default) REPL.
If in a REPL buffer already, use that unless a prefix is used (or
ALWAYS-ASK).  Otherwise get a list of all active inf-pilisp
REPLS and offer a choice.  It's recommended to rename REPL
buffers after they are created with `rename-buffer'."
  (interactive "P")
  (when-let ((new-repl-buffer
              (if (or always-ask
                      (not (inf-pilisp-repl-p)))
                  (inf-pilisp--prompt-repl-buffer "Select default REPL: ")
                (current-buffer))))
    (setq inf-pilisp-buffer new-repl-buffer)
    (message "Current inf-pilisp REPL set to %s" new-repl-buffer)))

(defvar inf-pilisp--repl-type-lock nil
  "Global lock for protecting against proc filter race conditions.
See http://blog.jorgenschaefer.de/2014/05/race-conditions-in-emacs-process-filter.html")

(defun inf-pilisp--prompt-repl-type ()
  "Set the REPL type to one of the available implementations."
  (interactive)
  (let ((types (mapcar #'car inf-pilisp-repl-features)))
    (intern
     (completing-read "Set REPL type: "
                      (sort (mapcar #'symbol-name types) #'string-lessp)))))

(defgroup inf-pilisp nil
  "Run an external PiLisp process (REPL) in an Emacs buffer."
  :prefix "inf-pilisp-"
  :group 'pilisp
  :link '(url-link :tag "GitHub" "https://github.com/pilisp-emacs/inf-pilisp")
  :link '(emacs-commentary-link :tag "Commentary" "inf-pilisp"))

(defconst inf-pilisp-version
  (or (if (fboundp 'package-get-version)
          (package-get-version))
      "3.2.1")
  "The current version of `inf-pilisp'.")

(defcustom inf-pilisp-prompt-read-only t
  "If non-nil, the prompt will be read-only.

Also see the description of `ielm-prompt-read-only'."
  :type 'boolean)

(defcustom inf-pilisp-filter-regexp
  "\\`\\s *\\(:\\(\\w\\|\\s_\\)\\)?\\s *\\'"
  "What not to save on inferior PiLisp's input history.
Input matching this regexp is not saved on the input history in Inferior PiLisp
mode.  Default is whitespace followed by 0 or 1 single-letter colon-keyword
\(as in :a, :c, etc.)"
  :type 'regexp)

(defun inf-pilisp--modeline-info ()
  "Return modeline info for `inf-pilisp-minor-mode'.
Either \"no process\" or \"buffer-name(repl-type)\""
  (if (and (bufferp inf-pilisp-buffer)
           (buffer-live-p inf-pilisp-buffer))
      (with-current-buffer inf-pilisp-buffer
        (format "%s(%s)" (buffer-name (current-buffer)) inf-pilisp-repl-type))
    "no process"))

(defvar inf-pilisp-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map (kbd "C-x C-e") #'inf-pilisp-eval-last-sexp)
    (define-key map (kbd "C-c C-l") #'inf-pilisp-load-file)
    (define-key map (kbd "C-c C-a") #'inf-pilisp-show-arglists)
    (define-key map (kbd "C-c C-d") #'inf-pilisp-show-binding-documentation)
    ;; (define-key map (kbd "C-c C-s") #'inf-pilisp-show-var-source)
    ;; (define-key map (kbd "C-c C-S-a") #'inf-pilisp-apropos)
    (define-key map (kbd "C-c M-o") #'inf-pilisp-clear-repl-buffer)
    (define-key map (kbd "C-c C-q") #'inf-pilisp-quit)
    (define-key map (kbd "C-c C-z") #'inf-pilisp-switch-to-recent-buffer)
    (easy-menu-define inf-pilisp-mode-menu map
      "Inferior PiLisp REPL Menu"
      '("Inf-PiLisp REPL"
        ["Eval last sexp" inf-pilisp-eval-last-sexp t]
        "--"
        ["Load file" inf-pilisp-load-file t]
        "--"
        ["Show arglists" inf-pilisp-show-arglists t]
        ["Show documentation for binding" inf-pilisp-show-binding-documentation t]
        ;; ["Show source for var" inf-pilisp-show-var-source t]
        ;; ["Apropos" inf-pilisp-apropos t]
        "--"
        ["Clear REPL" inf-pilisp-clear-repl-buffer]
        ["Restart" inf-pilisp-restart]
        ["Quit" inf-pilisp-quit]
        "--"
        ["Version" inf-pilisp-display-version]))
    map))

(defvar inf-pilisp-insert-commands-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "d") #'inf-pilisp-insert-defun)
    (define-key map (kbd "C-d") #'inf-pilisp-insert-defun)
    (define-key map (kbd "e") #'inf-pilisp-insert-last-sexp)
    (define-key map (kbd "C-e") #'inf-pilisp-insert-last-sexp)
    map))

(defvar inf-pilisp-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-x")  #'inf-pilisp-eval-defun)     ; Gnu convention
    (define-key map (kbd "C-x C-e") #'inf-pilisp-eval-last-sexp) ; Gnu convention
    (define-key map (kbd "C-c C-e") #'inf-pilisp-eval-last-sexp)
    (define-key map (kbd "C-c C-c") #'inf-pilisp-eval-defun)     ; SLIME/CIDER style
    (define-key map (kbd "C-c C-b") #'inf-pilisp-eval-buffer)
    (define-key map (kbd "C-c C-r") #'inf-pilisp-eval-region)
    (define-key map (kbd "C-c M-r") #'inf-pilisp-reload)
    (define-key map (kbd "C-c C-n") #'inf-pilisp-eval-form-and-next)
    (define-key map (kbd "C-c C-j") inf-pilisp-insert-commands-map)
    (define-key map (kbd "C-c C-z") #'inf-pilisp-switch-to-repl)
    (define-key map (kbd "C-c C-i") #'inf-pilisp-show-ns-vars)
    ;; (define-key map (kbd "C-c C-S-a") #'inf-pilisp-apropos)
    (define-key map (kbd "C-c C-m") #'inf-pilisp-macroexpand)
    (define-key map (kbd "C-c C-l") #'inf-pilisp-load-file)
    (define-key map (kbd "C-c C-a") #'inf-pilisp-show-arglists)
    (define-key map (kbd "C-c C-d") #'inf-pilisp-show-binding-documentation)
    ;; (define-key map (kbd "C-c C-s") #'inf-pilisp-show-var-source)
    (define-key map (kbd "C-c M-n") #'inf-pilisp-set-ns)
    (define-key map (kbd "C-c C-q") #'inf-pilisp-quit)
    (define-key map (kbd "C-c M-c") #'inf-pilisp-connect)
    (easy-menu-define inf-pilisp-minor-mode-menu map
      "Inferior PiLisp Minor Mode Menu"
      '("Inf-PiLisp"
        ["Eval top-level sexp at point" inf-pilisp-eval-defun t]
        ["Eval last sexp" inf-pilisp-eval-last-sexp t]
        ["Eval region" inf-pilisp-eval-region t]
        ["Eval buffer" inf-pilisp-eval-buffer t]
        "--"
        ["Load file..." inf-pilisp-load-file t]
        ["Reload file... " inf-pilisp-reload t]
        "--"
        ["Switch to REPL" inf-pilisp-switch-to-repl t]
        ["Set REPL ns" inf-pilisp-set-ns t]
        "--"
        ["Show arglists" inf-pilisp-show-arglists t]
        ["Show documentation for binding" inf-pilisp-show-binding-documentation t]
        ;; ["Show source for var" inf-pilisp-show-var-source t]
        ["Show vars in ns" inf-pilisp-show-ns-vars t]
        ;; ["Apropos" inf-pilisp-apropos t]
        ["Macroexpand" inf-pilisp-macroexpand t]
        "--"
        ["Restart REPL" inf-pilisp-restart]
        ["Quit REPL" inf-pilisp-quit]))
    map))

;;;###autoload
(defcustom inf-pilisp-mode-line
  '(:eval (format " inf-pilisp[%s]" (inf-pilisp--modeline-info)))
  "Mode line lighter for cider mode.

The value of this variable is a mode line template as in
`mode-line-format'.  See Info Node `(elisp)Mode Line Format' for details
about mode line templates.

Customize this variable to change how inf-pilisp-minor-mode
displays its status in the mode line.  The default value displays
the current REPL.  Set this variable to nil to disable the
mode line entirely."
  :type 'sexp
  :risky t)

(defcustom inf-pilisp-enable-eldoc t
  "Var that allows disabling `eldoc-mode' in `inf-pilisp'.

Set to nil to disable eldoc.  Eldoc can be quite useful by
displaying function signatures in the modeline, but can also
cause multiple prompts to appear in the REPL and mess with *1,
*2, etc."
  :type 'boolean
  :safe #'booleanp
  :package-version '(inf-pilisp . "3.2.0"))

;;;###autoload
(define-minor-mode inf-pilisp-minor-mode
  "Minor mode for interacting with the inferior PiLisp process buffer.

The following commands are available:

\\{inf-pilisp-minor-mode-map}"
  :lighter inf-pilisp-mode-line
  :keymap inf-pilisp-minor-mode-map
  (setq-local comint-input-sender 'inf-pilisp--send-string)
  (when inf-pilisp-enable-eldoc
    (inf-pilisp-eldoc-setup))
  (make-local-variable 'completion-at-point-functions)
  (add-to-list 'completion-at-point-functions
               #'inf-pilisp-completion-at-point))

(defun inf-pilisp--endpoint-p (x)
  "Return non-nil if and only if X is a valid endpoint.

A valid endpoint consists of a host and port
number (e.g. (\"localhost\" . 5555))."
  (and
   (listp x)
   (stringp (car x))
   (numberp (cdr x))))

(defcustom inf-pilisp-custom-startup
   nil
   "Form to be used to start `inf-pilisp'.
Can be a cons pair of (host . port) where host is a string and
port is an integer, or a string to startup an interpreter like
\"planck\"."
   :type '(choice (cons string integer) (const nil)))

(defcustom inf-pilisp-custom-repl-type
  nil
  "REPL type to use for `inf-pilisp' process buffer.
Should be a symbol that is a key in `inf-pilisp-repl-features'."
  :package-version '(inf-pilisp . "3.0.0")
  :type '(choice (const :tag "pilisp" pilisp)
                 (const :tag "cljs" cljs)
                 (const :tag "lumo" lumo)
                 (const :tag "planck" planck)
                 (const :tag "joker" joker)
                 (const :tag "babashka" babashka)
                 (const :tag "determine at startup" nil)))

(defun inf-pilisp--whole-comment-line-p (string)
  "Return non-nil iff STRING is a whole line semicolon comment."
  (string-match-p "^\s*;" string))

(defun inf-pilisp--sanitize-command (command)
  "Sanitize COMMAND for sending it to a process.
An example of things that this function does is to add a final
newline at the end of the form.  Return an empty string if the
sanitized command is empty."
  (let ((sanitized (string-trim-right command)))
    (if (string-blank-p sanitized)
        ""
      (concat sanitized "\n"))))

(defun inf-pilisp--send-string (proc string)
  "A custom `comint-input-sender` / `comint-send-string`.
It performs the required side effects on every send for PROC and
STRING (for example set the buffer local REPL type).  It should
always be preferred over `comint-send-string`.  It delegates to
`comint-simple-send` so it always appends a newline at the end of
the string for evaluation.  Refer to `comint-simple-send` for
customizations."
  (let ((sanitized (inf-pilisp--sanitize-command string)))
    (inf-pilisp--log-string sanitized "----CMD->")
    (comint-send-string proc sanitized)))

(defcustom inf-pilisp-reload-form "(require '%s :reload)"
  "Format-string for building a PiLisp expression to reload a file.
Reload forces loading of all the identified libs even if they are
already loaded.
This format string should use `%s' to substitute a namespace and
should result in a PiLisp form that will be sent to the inferior
PiLisp to load that file."
  :type 'string
  :safe #'stringp
  :package-version '(inf-pilisp . "2.2.0"))

;; :reload forces loading of all the identified libs even if they are
  ;; already loaded
;; :reload-all implies :reload and also forces loading of all libs that the
;; identified libs directly or indirectly load via require or use

(defun inf-pilisp-reload-form (_proc)
  "Return the form to query the Inf-PiLisp PROC for reloading a namespace.
If you are using REPL types, it will pickup the most appropriate
`inf-pilisp-reload-form` variant."
  inf-pilisp-reload-form)

(defcustom inf-pilisp-reload-all-form "(require '%s :reload-all)"
  "Format-string for building a PiLisp expression to :reload-all a file.
Reload-all implies :reload and also forces loading of all libs
that the identified libs directly or indirectly load via require
or use.
This format string should use `%s' to substitute a namespace and
should result in a PiLisp form that will be sent to the inferior
PiLisp to load that file."
  :type 'string
  :safe #'stringp
  :package-version '(inf-pilisp . "2.2.0"))

(defun inf-pilisp-reload-all-form (_proc)
  "Return the form to query the Inf-PiLisp PROC for :reload-all of a namespace.
If you are using REPL types, it will pickup the most appropriate
`inf-pilisp-reload-all-form` variant."
  inf-pilisp-reload-all-form)

(defcustom inf-pilisp-prompt "^pl> *" ;; "^[^pl> \n]+pl> *"
  "Regexp to recognize prompts in the Inferior PiLisp mode."
  :type 'regexp)

(defcustom inf-pilisp-subprompt " *#_pl> *"
  "Regexp to recognize subprompts in the Inferior PiLisp mode."
  :type 'regexp)

(defcustom inf-pilisp-comint-prompt-regexp "^pl> *" ;; "^\\( *#_\\|[^pl> \n]+\\)pl> *"
  "Regexp to recognize both main prompt and subprompt for comint.
This should usually be a combination of `inf-pilisp-prompt' and
`inf-pilisp-subprompt'."
  :type 'regexp)

(defcustom inf-pilisp-repl-use-same-window nil
  "Controls whether to display the REPL buffer in the current window or not."
  :type '(choice (const :tag "same" t)
                 (const :tag "different" nil))
  :safe #'booleanp
  :package-version '(inf-pilisp . "2.0.0"))

(defcustom inf-pilisp-auto-mode t
  "When non-nil, automatically enable inf-pilisp-minor-mode for all PiLisp buffers."
  :type 'boolean
  :safe #'booleanp
  :package-version '(inf-pilisp . "3.1.0"))

(defun inf-pilisp--pilisp-buffers ()
  "Return a list of all existing `pilisp-mode' buffers."
  (cl-remove-if-not
   (lambda (buffer) (with-current-buffer buffer (derived-mode-p 'pilisp-mode)))
   (buffer-list)))

(defun inf-pilisp-enable-on-existing-pilisp-buffers ()
  "Enable inf-pilisp's minor mode on existing PiLisp buffers.
See command `inf-pilisp-minor-mode'."
  (interactive)
  (add-hook 'pilisp-mode-hook #'inf-pilisp-minor-mode)
  (dolist (buffer (inf-pilisp--pilisp-buffers))
    (with-current-buffer buffer
      (inf-pilisp-minor-mode +1))))

(defun inf-pilisp-disable-on-existing-pilisp-buffers ()
  "Disable command `inf-pilisp-minor-mode' on existing PiLisp buffers."
  (interactive)
  (dolist (buffer (inf-pilisp--pilisp-buffers))
    (with-current-buffer buffer
      (inf-pilisp-minor-mode -1))))

(define-derived-mode inf-pilisp-mode comint-mode "Inferior PiLisp"
  "Major mode for interacting with an inferior PiLisp process.
Runs a PiLisp interpreter as a subprocess of Emacs, with PiLisp
I/O through an Emacs buffer.  Variables of the type
`inf-pilisp-*-cmd' combined with the project type controls how
a PiLisp REPL is started.  Variables `inf-pilisp-prompt',
`inf-pilisp-filter-regexp' and `inf-pilisp-load-form' can
customize this mode for different PiLisp REPLs.

For information on running multiple processes in multiple buffers, see
documentation for variable `inf-pilisp-buffer'.

\\{inf-pilisp-mode-map}

Customization: Entry to this mode runs the hooks on `comint-mode-hook' and
`inf-pilisp-mode-hook' (in that order).

You can send text to the inferior PiLisp process from other buffers containing
PiLisp source.
    `inf-pilisp-switch-to-repl' switches the current buffer to the PiLisp process buffer.
    `inf-pilisp-eval-defun' sends the current defun to the PiLisp process.
    `inf-pilisp-eval-region' sends the current region to the PiLisp process.

    Prefixing the inf-pilisp-eval/defun/region commands with
    a \\[universal-argument] causes a switch to the PiLisp process buffer after sending
    the text.

Commands:\\<inf-pilisp-mode-map>
\\[comint-send-input] after the end of the process' output sends the text from the
    end of process to point.
\\[comint-send-input] before the end of the process' output copies the sexp ending at point
    to the end of the process' output, and sends it.
\\[comint-copy-old-input] copies the sexp ending at point to the end of the process' output,
    allowing you to edit it before sending it.
If `comint-use-prompt-regexp' is nil (the default), \\[comint-insert-input] on old input
   copies the entire old input to the end of the process' output, allowing
   you to edit it before sending it.  When not used on old input, or if
   `comint-use-prompt-regexp' is non-nil, \\[comint-insert-input] behaves according to
   its global binding.
\\[backward-delete-char-untabify] converts tabs to spaces as it moves back.
\\[clojure-indent-line] indents for PiLisp; with argument, shifts rest
    of expression rigidly with the current line.
\\[indent-sexp] does \\[clojure-indent-line] on each line starting within following expression.
Paragraphs are separated only by blank lines.  Semicolons start comments.
If you accidentally suspend your process, use \\[comint-continue-subjob]
to continue it."
  (setq comint-input-sender 'inf-pilisp--send-string)
  (setq comint-prompt-regexp inf-pilisp-comint-prompt-regexp)
  (setq mode-line-process '(":%s"))
  (clojure-mode-variables)
  (clojure-font-lock-setup)
  ;; TODO Fix eldoc
  ;; (when inf-pilisp-enable-eldoc
  ;;   (inf-pilisp-eldoc-setup))
  (setq comint-get-old-input #'inf-pilisp-get-old-input)
  (setq comint-input-filter #'inf-pilisp-input-filter)
  (setq-local comint-prompt-read-only inf-pilisp-prompt-read-only)
  (add-hook 'comint-preoutput-filter-functions #'inf-pilisp-preoutput-filter nil t)
  (add-hook 'completion-at-point-functions #'inf-pilisp-completion-at-point nil t)
  (ansi-color-for-comint-mode-on)
  (when inf-pilisp-auto-mode
    (inf-pilisp-enable-on-existing-pilisp-buffers)))

(defun inf-pilisp-get-old-input ()
  "Return a string containing the sexp ending at point."
  (save-excursion
    (let ((end (point)))
      (backward-sexp)
      (buffer-substring (max (point) (comint-line-beginning-position)) end))))

(defun inf-pilisp-input-filter (str)
  "Return t if STR does not match `inf-pilisp-filter-regexp'."
  (not (string-match inf-pilisp-filter-regexp str)))

(defun inf-pilisp-chomp (string)
  "Remove final newline from STRING."
  (if (string-match "[\n]\\'" string)
      (replace-match "" t t string)
    string))

(defun inf-pilisp-remove-subprompts (string)
  "Remove subprompts from STRING."
  (replace-regexp-in-string inf-pilisp-subprompt "" string))

(defun inf-pilisp-preoutput-filter (str)
  "Preprocess the output STR from interactive commands."
  (inf-pilisp--log-string str "<-RES----")
  (cond
   ((string-prefix-p "inf-pilisp-" (symbol-name (or this-command last-command)))
    ;; Remove subprompts and prepend a newline to the output string
    (inf-pilisp-chomp (concat "\n" (inf-pilisp-remove-subprompts str))))
   (t str)))

(defun inf-pilisp-clear-repl-buffer ()
  "Clear the REPL buffer."
  (interactive)
  (with-current-buffer (if (derived-mode-p 'inf-pilisp-mode)
                           (current-buffer)
                         inf-pilisp-buffer)
    (let ((comint-buffer-maximum-size 0))
      (comint-truncate-buffer))))

(defun inf-pilisp--swap-to-buffer-window (to-buffer)
  "Switch to `TO-BUFFER''s window."
  (let ((pop-up-frames
         ;; Be willing to use another frame
         ;; that already has the window in it.
         (or pop-up-frames
             (get-buffer-window to-buffer t))))
    (pop-to-buffer to-buffer '(display-buffer-reuse-window . ()))))

(defun inf-pilisp-switch-to-repl (eob-p)
  "Switch to the inferior PiLisp process buffer.
With prefix argument EOB-P, positions cursor at end of buffer."
  (interactive "P")
  (if (get-buffer-process inf-pilisp-buffer)
      (inf-pilisp--swap-to-buffer-window inf-pilisp-buffer)
    (call-interactively #'inf-pilisp))
  (when eob-p
    (push-mark)
    (goto-char (point-max))))

(defun inf-pilisp-switch-to-recent-buffer ()
  "Switch to the most recently used `inf-pilisp-minor-mode' buffer."
  (interactive)
  (let ((recent-inf-pilisp-minor-mode-buffer (seq-find (lambda (buf)
                                                          (with-current-buffer buf (bound-and-true-p inf-pilisp-minor-mode)))
                                                        (buffer-list))))
    (if recent-inf-pilisp-minor-mode-buffer
        (inf-pilisp--swap-to-buffer-window recent-inf-pilisp-minor-mode-buffer)
      (message "inf-pilisp: No recent buffer known."))))

(defun inf-pilisp-quit (&optional buffer)
  "Kill the REPL buffer and its underlying process.

You can pass the target BUFFER as an optional parameter
to suppress the usage of the target buffer discovery logic."
  (interactive)
  (let ((target-buffer (or buffer (inf-pilisp-select-target-repl))))
    (when (get-buffer-process target-buffer)
      (delete-process target-buffer))
    (kill-buffer target-buffer)))

(defun inf-pilisp-restart (&optional buffer)
  "Restart the REPL buffer and its underlying process.

You can pass the target BUFFER as an optional parameter
to suppress the usage of the target buffer discovery logic."
  (interactive)
  (let* ((target-buffer (or buffer (inf-pilisp-select-target-repl)))
         (target-buffer-name (buffer-name target-buffer)))
    ;; TODO: Try to recycle the old buffer instead of killing and recreating it
    (inf-pilisp-quit target-buffer)
    (call-interactively #'inf-pilisp)
    (rename-buffer target-buffer-name)))

(defun inf-pilisp--project-name (dir)
  "Extract a project name from a project DIR.
The name is simply the final segment of the path."
  (file-name-nondirectory (directory-file-name dir)))

;;;###autoload
(defun inf-pilisp (cmd)
  "Run an inferior PiLisp process, input and output via buffer `*inf-pilisp*'.
If there is a process already running in `*inf-pilisp*', just
switch to that buffer.

CMD is a string which serves as the startup command or a cons of
host and port.

 Prompts user for repl startup command and repl type if not
inferrable from startup command.  Uses `inf-pilisp-custom-repl-type'
and `inf-pilisp-custom-startup' if those are set.
Use a prefix to prevent using these when they
are set.

 Runs the hooks from `inf-pilisp-mode-hook' (after the
`comint-mode-hook' is run).  \(Type \\[describe-mode] in the
process buffer for a list of commands.)"
  (interactive (list (or (unless current-prefix-arg
                           inf-pilisp-custom-startup)
                         ;; TODO Consider best way to streamline given one REPL type.
                         (completing-read "Select PiLisp REPL startup command: "
                                          (mapcar #'cdr inf-pilisp-startup-forms)
                                          nil
                                          'confirm-after-completion))))
  (let* ((project-dir nil ;; (pilisp-project-dir)
                      )
         (process-buffer-name (if project-dir
                                  (format "inf-pilisp %s" (inf-pilisp--project-name project-dir))
                                "inf-pilisp"))
         ;; comint adds the asterisks to both sides
         (repl-buffer-name (format "*%s*" process-buffer-name)))
    ;; Create a new comint buffer if needed
    (unless (comint-check-proc repl-buffer-name)
      ;; run the new process in the project's root when in a project folder
      (let ((default-directory (or project-dir default-directory))
            (cmdlist (if (consp cmd)
                         (list cmd)
                       (split-string-and-unquote cmd)))
            (repl-type (or (unless prefix-arg
                             inf-pilisp-custom-repl-type)
                           (car (rassoc cmd inf-pilisp-startup-forms))
                           (inf-pilisp--prompt-repl-type))))
        (message "Starting PiLisp REPL via `%s'..." cmd)
        (with-current-buffer (apply #'make-comint
                                    process-buffer-name (car cmdlist) nil (cdr cmdlist))
          (inf-pilisp-mode)
          (set-syntax-table clojure-mode-syntax-table)
          (setq-local inf-pilisp-repl-type repl-type)
          (hack-dir-local-variables-non-file-buffer))))
    ;; update the default comint buffer and switch to it
    (setq inf-pilisp-buffer (get-buffer repl-buffer-name))
    (if inf-pilisp-repl-use-same-window
        (pop-to-buffer-same-window repl-buffer-name)
      (pop-to-buffer repl-buffer-name))))

;;;###autoload
(defun inf-pilisp-connect (host port)
  "Connect to a running socket REPL server via `inf-pilisp'.
HOST is the host the process is running on, PORT is where it's listening."
  (interactive "shost: \nnport: ")
  (inf-pilisp (cons host port)))

(defun inf-pilisp--forms-without-newlines (str)
  "Remove newlines between toplevel forms.
STR is a string of contents to be evaluated.  When sending
multiple forms to a REPL, each newline triggers a prompt.
So we replace all newlines between top level forms but not inside
of forms."
  (condition-case nil
      (with-temp-buffer
        (progn
          (pilisp-mode)
          (insert str)
          (whitespace-cleanup)
          (goto-char (point-min))
          (while (not (eobp))
            (while (looking-at "\n")
              (delete-char 1))
            (unless (eobp)
              (clojure-forward-logical-sexp))
            (unless (eobp)
              (forward-char)))
          (buffer-substring-no-properties (point-min) (point-max))))
    (scan-error str)))

(defun inf-pilisp-eval-region (start end &optional and-go)
  "Send the current region to the inferior PiLisp process.
Sends substring between START and END.  Prefix argument AND-GO
means switch to the PiLisp buffer afterwards."
  (interactive "r\nP")
  (let* ((str (buffer-substring-no-properties start end))
         ;; newlines over a socket repl between top level forms cause
         ;; a prompt to be returned. so here we dump the region into a
         ;; temp buffer, and delete all newlines between the forms
         (formatted (inf-pilisp--forms-without-newlines str)))
    (inf-pilisp--send-string (inf-pilisp-proc) formatted))
  (when and-go (inf-pilisp-switch-to-repl t)))

(defun inf-pilisp-eval-string (code)
  "Send the string CODE to the inferior PiLisp process to be executed."
  (inf-pilisp--send-string (inf-pilisp-proc) code))

(defun inf-pilisp--defun-at-point (&optional bounds)
  "Return text or range of defun at point.
If BOUNDS is truthy return a dotted pair of beginning and end of
current defun else return the string.."
  (save-excursion
    (end-of-defun)
    (let ((end (point))
          (case-fold-search t)
          (func (if bounds #'cons #'buffer-substring-no-properties)))
      (beginning-of-defun)
      (funcall func (point) end))))

(defun inf-pilisp-eval-defun (&optional and-go)
  "Send the current defun to the inferior PiLisp process.
Prefix argument AND-GO means switch to the PiLisp buffer afterwards."
  (interactive "P")
  (save-excursion
    (let ((bounds (inf-pilisp--defun-at-point t)))
     (inf-pilisp-eval-region (car bounds) (cdr bounds) and-go))))

(defun inf-pilisp-eval-buffer (&optional and-go)
  "Send the current buffer to the inferior PiLisp process.
Prefix argument AND-GO means switch to the PiLisp buffer afterwards."
  (interactive "P")
  (save-excursion
    (widen)
    (let ((case-fold-search t))
      (inf-pilisp-eval-region (point-min) (point-max) and-go))))

(defun inf-pilisp-eval-last-sexp (&optional and-go)
  "Send the previous sexp to the inferior PiLisp process.
Prefix argument AND-GO means switch to the PiLisp buffer afterwards."
  (interactive "P")
  (inf-pilisp-eval-region (save-excursion (backward-sexp) (point)) (point) and-go))

(defun inf-pilisp-eval-form-and-next ()
  "Send the previous sexp to the inferior PiLisp process and move to the next one."
  (interactive "")
  (while (not (zerop (car (syntax-ppss))))
    (up-list))
  (inf-pilisp-eval-last-sexp)
  (forward-sexp))

(defun inf-pilisp-insert-and-eval (form)
  "Insert FORM into process and evaluate.
Indent FORM.  FORM is expected to have been trimmed."
  (let ((pilisp-process (inf-pilisp-proc)))
    ;; ensure the repl buffer scrolls. See similar fix in CIDER:
    ;; https://github.com/pilisp-emacs/cider/pull/2590
    (with-selected-window (or (get-buffer-window inf-pilisp-buffer)
                              (selected-window))
      (with-current-buffer (process-buffer pilisp-process)
        (comint-goto-process-mark)
        (let ((beginning (point)))
          (insert form)
          (let ((end (point)))
            (goto-char beginning)
            (indent-sexp end)
            ;; font-lock the inserted code
            (font-lock-ensure beginning end)
            (goto-char end)))
        (comint-send-input t t)))))

(defun inf-pilisp-insert-defun ()
  "Send current defun to process."
  (interactive)
  (inf-pilisp-insert-and-eval (string-trim (inf-pilisp--defun-at-point))))

(defun inf-pilisp-insert-last-sexp ()
  "Send last sexp to process."
  (interactive)
  (inf-pilisp-insert-and-eval
   (buffer-substring-no-properties (save-excursion (backward-sexp) (point))
                                   (point))))

;; Now that inf-pilisp-eval-/defun/region takes an optional prefix arg,
;; these commands are redundant. But they are kept around for the user
;; to bind if he wishes, for backwards functionality, and because it's
;; easier to type C-c e than C-u C-c C-e.

(defun inf-pilisp-eval-region-and-go (start end)
  "Send the current region to the inferior PiLisp, and switch to its buffer.
START and END are the beginning and end positions in the buffer to send."
  (interactive "r")
  (inf-pilisp-eval-region start end t))

(defun inf-pilisp-eval-defun-and-go ()
  "Send the current defun to the inferior PiLisp, and switch to its buffer."
  (interactive)
  (inf-pilisp-eval-defun t))

(defvar inf-pilisp-prev-l/c-dir/file nil
  "Record last directory and file used in loading or compiling.
This holds a cons cell of the form `(DIRECTORY . FILE)'
describing the last `inf-pilisp-load-file' command.")

(defcustom inf-pilisp-source-modes '(pilisp-mode)
  "Used to determine if a buffer contains PiLisp source code.
If it's loaded into a buffer that is in one of these major modes, it's
considered a PiLisp source file by `inf-pilisp-load-file'.
Used by this command to determine defaults."
  :type '(repeat symbol))

;; TODO Consider additional inf-pilisp-load-current-file or making this that. The comint default selection still requires typing out the file name until it matches, which is suboptimal.
(defun inf-pilisp-load-file (&optional switch-to-repl file-name)
  "Load a PiLisp file into the inferior PiLisp process.

The prefix argument SWITCH-TO-REPL controls whether to switch to
REPL after the file is loaded or not.  If the argument FILE-NAME
is present it will be used instead of the current file."
  (interactive "P")
  (let* ((proc (inf-pilisp-proc))
         (file-name (or file-name
                        (car (comint-get-source "Load PiLisp file: " inf-pilisp-prev-l/c-dir/file
                                                inf-pilisp-source-modes t))))
         (load-form (inf-pilisp-get-feature proc 'load)))
    (comint-check-source file-name) ; Check to see if buffer needs saved.
    (setq inf-pilisp-prev-l/c-dir/file (cons (file-name-directory    file-name)
                                              (file-name-nondirectory file-name)))
    (inf-pilisp--send-string proc (format load-form file-name))
    (when switch-to-repl
      (inf-pilisp-switch-to-repl t))))

;; TODO PiLisp doesn't have namespaces.
(defun inf-pilisp-reload (arg)
  "Send a query to the inferior PiLisp for reloading the namespace.
See variable `inf-pilisp-reload-form' and
`inf-pilisp-reload-all-form'.

The prefix argument ARG can change the behavior of the command:

  - C-u M-x `inf-pilisp-reload': prompts for a namespace name.
  - M-- M-x `inf-pilisp-reload': executes (require ... :reload-all).
  - M-- C-u M-x `inf-pilisp-reload': reloads all AND prompts."
  (interactive "P")
  (let* ((proc (inf-pilisp-proc))
         (reload-all-p (or (equal arg '-) (equal arg '(-4))))
         (prompt-p (or (equal arg '(4)) (equal arg '(-4))))
         (ns ""
             ;; (if prompt-p
             ;;    (car (inf-pilisp-symprompt "Namespace" (pilisp-find-ns)))
             ;;  (pilisp-find-ns))
             )
         (form (if (not reload-all-p)
                   (inf-pilisp-reload-form proc)
                 (inf-pilisp-reload-all-form proc))))
    (inf-pilisp--send-string proc (format form ns))))

(defun inf-pilisp-connected-p ()
  "Return t if inferior PiLisp is currently connected, nil otherwise."
  (not (null inf-pilisp-buffer)))



;;; Ancillary functions
;;; ===================

(defun inf-pilisp-symprompt (prompt default)
  "Read a string from the user.

It allows to specify a PROMPT string and a DEFAULT string to
display."
  (list (let* ((prompt (if default
                           (format "%s (default %s): " prompt default)
                         (concat prompt ": ")))
               (ans (read-string prompt)))
          (if (zerop (length ans)) default ans))))


;; Adapted from function-called-at-point in help.el.
(defun inf-pilisp-fn-called-at-pt ()
  "Return the name of the function called in the current call.
The value is nil if it can't find one."
  (condition-case nil
      (save-excursion
        (save-restriction
          (narrow-to-region (max (point-min) (- (point) 1000)) (point-max))
          (backward-up-list 1)
          (forward-char 1)
          (let ((obj (read (current-buffer))))
            (and (symbolp obj) obj))))
    (error nil)))

(defun inf-pilisp-symbol-at-point ()
  "Return the name of the symbol at point, otherwise nil."
  (or (thing-at-point 'symbol) ""))

;;; Documentation functions: var doc and arglists.
;;; ======================================================================

(defun inf-pilisp-show-binding-documentation (prompt-for-symbol)
  "Send a form to the inferior PiLisp to give documentation for VAR.
See function `inf-pilisp-var-doc-form'.  When invoked with a
prefix argument PROMPT-FOR-SYMBOL, it prompts for a symbol name."
  (interactive "P")
  (let* ((proc (inf-pilisp-proc))
         (var (if prompt-for-symbol
                  (car (inf-pilisp-symprompt "Binding doc" (inf-pilisp-symbol-at-point)))
                (inf-pilisp-symbol-at-point)))
         (doc-form (inf-pilisp-get-feature proc 'doc)))
    (inf-pilisp--send-string proc (format doc-form var))))

;; (defun inf-pilisp-show-var-source (prompt-for-symbol)
;;   "Send a command to the inferior PiLisp to give source for VAR.
;; See variable `inf-pilisp-var-source-form'.  When invoked with a
;; prefix argument PROMPT-FOR-SYMBOL, it prompts for a symbol name."
;;   (interactive "P")
;;   (let* ((proc (inf-pilisp-proc))
;;          (var (if prompt-for-symbol
;;                   (car (inf-pilisp-symprompt "Var source" (inf-pilisp-symbol-at-point)))
;;                 (inf-pilisp-symbol-at-point)))
;;          (source-form (inf-pilisp-get-feature proc 'source)))
;;     (inf-pilisp--send-string proc (format source-form var))))

;;;; Response parsing
;;;; ================

(defvar inf-pilisp--redirect-buffer-name " *Inf-PiLisp Redirect Buffer*"
  "The name of the buffer used for process output redirection.")

(defvar inf-pilisp--log-file-name ".inf-pilisp.log"
  "The name of the file used to log process activity.")

(defvar inf-pilisp-log-activity nil
  "Log process activity?.
Inf-PiLisp will create a log file in the project folder named
`inf-pilisp--log-file-name' and dump the process activity in it
in case this is not nil." )

(defun inf-pilisp--log-string (string &optional tag)
  "Log STRING to file, according to `inf-pilisp-log-response'.
The optional TAG will be converted to string and printed before
STRING if present."
  (when inf-pilisp-log-activity
    (write-region (concat "\n"
                          (when tag
                            (if (stringp tag)
                              (concat tag "\n")
                              (concat (prin1-to-string tag) "\n")))
                          (let ((print-escape-newlines t))
                            (prin1-to-string (substring-no-properties string))))
                  nil
                  (expand-file-name inf-pilisp--log-file-name
                                    ;; TODO PiLisp project dir.
                                    (clojure-project-dir))
                  'append
                  'no-annoying-write-file-in-minibuffer)))

(defun inf-pilisp--string-boundaries (string prompt &optional beg-regexp end-regexp)
  "Calculate the STRING boundaries, including PROMPT.
Return a list of positions (beginning end prompt).  If the
optional BEG-REGEXP and END-REGEXP are present, the boundaries
are going to match those."
  (list (or (and beg-regexp (string-match beg-regexp string)) 0)
        (or (and end-regexp (when (string-match end-regexp string)
                              (match-end 0)))
            (length string))
        (or (string-match prompt string) (length string))))

(defun inf-pilisp--get-redirect-buffer ()
  "Get the redirection buffer, creating it if necessary.

It is the buffer used for processing REPL responses, see variable
\\[inf-pilisp--redirect-buffer-name]."
  (or (get-buffer inf-pilisp--redirect-buffer-name)
      (let ((buffer (generate-new-buffer inf-pilisp--redirect-buffer-name)))
        (with-current-buffer buffer
          (hack-dir-local-variables-non-file-buffer)
          buffer))))

;; Originally from:
;;   https://github.com/glycerine/lush2/blob/master/lush2/etc/lush.el#L287
(defun inf-pilisp--process-response (command process &optional beg-regexp end-regexp)
  "Send COMMAND to PROCESS and return the response.
Return the result of COMMAND, filtering it from BEG-REGEXP to the
end of the matching END-REGEXP if non-nil.
If BEG-REGEXP is nil, the result string will start from (point)
in the results buffer.  If END-REGEXP is nil, the result string
will end at (point-max) in the results buffer.  It cuts out the
output from and including the `inf-pilisp-prompt`."
  (let ((redirect-buffer-name inf-pilisp--redirect-buffer-name)
        (sanitized-command (inf-pilisp--sanitize-command command)))
    (when (not (string-empty-p sanitized-command))
      (inf-pilisp--log-string command "----CMD->")
      (with-current-buffer (inf-pilisp--get-redirect-buffer)
        (erase-buffer)
        (comint-redirect-send-command-to-process sanitized-command redirect-buffer-name process nil t))
      ;; Wait for the process to complete
      (with-current-buffer (process-buffer process)
        (while (and (null comint-redirect-completed)
                    (accept-process-output process 1 0 t))
          (sleep-for 0.01)))
      ;; Collect the output
      (with-current-buffer redirect-buffer-name
        (goto-char (point-min))
        (let* ((buffer-string (buffer-substring-no-properties (point-min) (point-max)))
               (boundaries (inf-pilisp--string-boundaries buffer-string inf-pilisp-prompt beg-regexp end-regexp))
               (beg-pos (car boundaries))
               (end-pos (car (cdr boundaries)))
               (prompt-pos (car (cdr (cdr boundaries))))
               (response-string (substring buffer-string beg-pos (min end-pos prompt-pos))))
          (inf-pilisp--log-string buffer-string "<-RES----")
          response-string)))))

(defun inf-pilisp--nil-string-match-p (string)
  "Return non-nil iff STRING is not nil.
This function also takes into consideration weird escape
character and matches if nil is anywhere within the input
string."
  (string-match-p "\\Ca*nil\\Ca*" string))

(defun inf-pilisp--some (data)
  "Return DATA unless nil or includes \"nil\" as string."
  (cond
   ((null data) nil)
   ((and (stringp data)
         (inf-pilisp--nil-string-match-p data)) nil)
   (t data)))

(defun inf-pilisp--read-or-nil (response)
  "Read RESPONSE and return it as data.

If response is nil or includes the \"nil\" string return nil
instead.

Note that the read operation will always return the first
readable sexp only."
  ;; The following reads the first LISP expression
  (inf-pilisp--some
   (when response
     (ignore-errors (read response)))))

(defun inf-pilisp--process-response-match-p (match-p proc form)
  "Eval MATCH-P on the response of sending to PROC the input FORM.
Note that this function will add a \n to the end of the string
for evaluation, therefore FORM should not include it."
  (let ((response (inf-pilisp--process-response form proc)))
    (when response (funcall match-p response))))

(defun inf-pilisp--some-response-p (proc form)
  "Return non-nil iff PROC's response after evaluating FORM is not nil."
  (inf-pilisp--process-response-match-p
   (lambda (string)
     (not (inf-pilisp--nil-string-match-p (string-trim string))))
   proc form))

;;;; Commands
;;;; ========

(defun inf-pilisp-arglists (fn)
  "Send a query to the inferior PiLisp for the arglists for function FN.
See variable `inf-pilisp-arglists-form'."
  (when-let ((proc (inf-pilisp-proc 'no-error)))
    (when-let ((arglists-form (inf-pilisp-get-feature proc 'arglists)))
      (thread-first (format arglists-form fn)
        (inf-pilisp--process-response proc "(" ")")
        (inf-pilisp--some)))))

(defun inf-pilisp-show-arglists (prompt-for-symbol)
  "Show the arglists for function FN in the mini-buffer.
See variable `inf-pilisp-arglists-form'.  When invoked with a
prefix argument PROMPT-FOR-SYMBOL, it prompts for a symbol name."
  (interactive "P")
  (let* ((fn (if prompt-for-symbol
                 (car (inf-pilisp-symprompt "Arglists" (inf-pilisp-fn-called-at-pt)))
               (inf-pilisp-fn-called-at-pt)))
         (eldoc (inf-pilisp-arglists fn)))
    (if eldoc
        (message "%s: %s" fn eldoc)
      (message "Arglists not supported for this repl"))))

;; TODO PiLisp doesn't have namespaces. Use (bindings) for this.
(defun inf-pilisp-show-ns-vars (prompt-for-ns)
  "Send a query to the inferior PiLisp for the public vars in NS.
See variable `inf-pilisp-ns-vars-form'.  When invoked with a
prefix argument PROMPT-FOR-NS, it prompts for a namespace name."
  (interactive "P")
  (let* ((proc (inf-pilisp-proc))
         (ns (if prompt-for-ns
                 (car (inf-pilisp-symprompt "Ns vars" (pilisp-find-ns)))
               (pilisp-find-ns)))
         (ns-vars-form (inf-pilisp-get-feature proc 'ns-vars)))
    (inf-pilisp--send-string proc (format ns-vars-form ns))))

;; TODO PiLisp doesn't have namespaces.
(defun inf-pilisp-set-ns (prompt-for-ns)
  "Set the ns of the inferior PiLisp process to NS.
See variable `inf-pilisp-set-ns-form'.  It defaults to the ns of
the current buffer.  When invoked with a prefix argument
PROMPT-FOR-NS, it prompts for a namespace name."
  (interactive "P")
  (let* ((proc (inf-pilisp-proc))
         (ns (if prompt-for-ns
                 (car (inf-pilisp-symprompt "Set ns to" (pilisp-find-ns)))
               (pilisp-find-ns)))
         (set-ns-form (inf-pilisp-get-feature proc 'set-ns)))
    (when (or (not ns) (equal ns ""))
      (user-error "No namespace selected"))
    (inf-pilisp--send-string proc (format set-ns-form ns))))

;; TODO Implement apropos in PiLisp
(defun inf-pilisp-apropos (expr)
  "Send an expression to the inferior PiLisp for apropos.
EXPR can be either a regular expression or a stringable
thing.  See variable `inf-pilisp-apropos-form'."
  (interactive (inf-pilisp-symprompt "Var apropos" (inf-pilisp-symbol-at-point)))
  (let* ((proc (inf-pilisp-proc))
         (apropos-form (inf-pilisp-get-feature proc 'apropos)))
    (inf-pilisp--send-string proc (format apropos-form expr))))

(defun inf-pilisp-macroexpand (&optional macro-1)
  "Send a form to the inferior PiLisp for macro expansion.
See variable `inf-pilisp-macroexpand-form'.
With a prefix arg MACRO-1 uses function `inf-pilisp-macroexpand-1-form'."
  (interactive "P")
  (let* ((proc (inf-pilisp-proc))
         (last-sexp (buffer-substring-no-properties (save-excursion (backward-sexp) (point)) (point)))
         (macroexpand-form (inf-pilisp-get-feature proc
                                                    (if macro-1
                                                        'macroexpand-1
                                                      'macroexpand))))
    (inf-pilisp--send-string
     proc
     (format macroexpand-form last-sexp))))

(defun inf-pilisp--list-or-nil (data)
  "Return DATA if and only if it is a list."
  (when (listp data) data))

(defun inf-pilisp-list-completions (response-str)
  "Parse completions from RESPONSE-STR.

Its only ability is to parse a Lisp list of candidate strings,
every other EXPR will be discarded and nil will be returned."
  (thread-first
      response-str
    (inf-pilisp--read-or-nil)
    (inf-pilisp--list-or-nil)))

(defcustom inf-pilisp-completions-fn 'inf-pilisp-list-completions
  "The function that parses completion results.

It is a single-arity function that will receive the REPL
evaluation result of \\[inf-pilisp-completion-form] as string and
should return elisp data compatible with your completion mode.

The easiest possible data passed in input is a list of
candidates (e.g.: (\"def\" \"defn\")) but more complex libraries
like `alexander-yakushev/compliment' can return other things like
edn.

The expected return depends on the mode that you use for
completion: usually it is something compatible with
\\[completion-at-point-functions] but other modes like
`company-mode' allow an even higher level of sophistication.

The default value is the `inf-pilisp-list-completions' function,
which is able to parse results in list form only.  You can peek
at its implementation for getting to know some utility functions
you might want to use in your customization."
  :type 'function
  :package-version '(inf-pilisp . "2.1.0"))

(defun inf-pilisp-completions (expr)
  "Return completions for the PiLisp expression starting with EXPR.

Under the hood it calls the function
\\[inf-pilisp-completions-fn] passing in the result of
evaluating \\[inf-pilisp-completion-form] at the REPL."
  (let* ((proc (inf-pilisp-proc 'no-error))
         (completion-form (inf-pilisp-get-feature proc 'completion t)))
    (when (and proc completion-form (not (string-blank-p expr)))
      (let ((completion-expr (format completion-form (substring-no-properties expr))))
        (funcall inf-pilisp-completions-fn
                 (inf-pilisp--process-response completion-expr proc "(" ")"))))))

(defconst inf-pilisp-pilisp-expr-break-chars "^[] \"'`><,;|&{()[@\\^]"
  "Regexp are hard.

This regex has been built in order to match the first of the
listed chars.  There are a couple of quirks to consider:

- the ] is always a special in elisp regex so you have to put it
  directly AFTER [ if you want to match it as literal.
- The ^ needs to be escaped with \\^.

Tests and `re-builder' are your friends.")

(defun inf-pilisp--kw-to-symbol (kw)
  "Convert the keyword KW to a symbol.

This guy was taken from CIDER, thanks folks."
  (when kw
    (replace-regexp-in-string "\\`:+" "" kw)))

(defun inf-pilisp-completion-bounds-of-expr-at-point ()
  "Return bounds of expression at point to complete."
  (when (not (memq (char-syntax (following-char)) '(?w ?_)))
    (save-excursion
      (let* ((end (point))
             (skipped-back (skip-chars-backward inf-pilisp-pilisp-expr-break-chars))
             (start (+ end skipped-back))
             (chars (or (thing-at-point 'symbol)
                        (inf-pilisp--kw-to-symbol (buffer-substring start end)))))
        (when (> (length chars) 0)
          (let ((first-char (substring-no-properties chars 0 1)))
            (when (string-match-p "[^0-9]" first-char)
              (cons (point) end))))))))

(defun inf-pilisp-completion-expr-at-point ()
  "Return expression at point to complete."
  (let ((bounds (inf-pilisp-completion-bounds-of-expr-at-point)))
    (and bounds
         (buffer-substring (car bounds) (cdr bounds)))))

(defun inf-pilisp-completion-at-point ()
  "Retrieve the list of completions and prompt the user.
Returns the selected completion or nil."
  (let ((bounds (inf-pilisp-completion-bounds-of-expr-at-point)))
    (when (and bounds (inf-pilisp-get-feature (inf-pilisp-proc) 'completion 'no-error))
      (list (car bounds) (cdr bounds)
            (if (fboundp 'completion-table-with-cache)
                (completion-table-with-cache #'inf-pilisp-completions)
              (completion-table-dynamic #'inf-pilisp-completions))))))

;;;; ElDoc
;;;; =====

(defvar inf-pilisp-extra-eldoc-commands '("yas-expand")
  "Extra commands to be added to eldoc's safe commands list.")

(defvar-local inf-pilisp-eldoc-last-symbol nil
  "The eldoc information for the last symbol we checked.")

(defun inf-pilisp-eldoc-format-thing (thing)
  "Format the eldoc THING."
  (propertize thing 'face 'font-lock-function-name-face))

(defun inf-pilisp-eldoc-beginning-of-sexp ()
  "Move to the beginning of current sexp.

Return the number of nested sexp the point was over or after."
  (let ((parse-sexp-ignore-comments t)
        (num-skipped-sexps 0))
    (condition-case _
        (progn
          ;; First account for the case the point is directly over a
          ;; beginning of a nested sexp.
          (condition-case _
              (let ((p (point)))
                (forward-sexp -1)
                (forward-sexp 1)
                (when (< (point) p)
                  (setq num-skipped-sexps 1)))
            (error))
          (while
              (let ((p (point)))
                (forward-sexp -1)
                (when (< (point) p)
                  (setq num-skipped-sexps (1+ num-skipped-sexps))))))
      (error))
    num-skipped-sexps))

(defun inf-pilisp-eldoc-info-in-current-sexp ()
  "Return a list of the current sexp and the current argument index."
  (save-excursion
    (let ((argument-index (1- (inf-pilisp-eldoc-beginning-of-sexp))))
      ;; If we are at the beginning of function name, this will be -1.
      (when (< argument-index 0)
        (setq argument-index 0))
      ;; Don't do anything if current word is inside a string, vector,
      ;; hash or set literal.
      (if (member (or (char-after (1- (point))) 0) '(?\" ?\{ ?\[))
          nil
        (list (inf-pilisp-symbol-at-point) argument-index)))))

(defun inf-pilisp-eldoc-arglists (thing)
  "Return the arglists for THING."
  (when (and thing
             (not (string= thing ""))
             (not (string-prefix-p ":" thing)))
    ;; check if we can used the cached eldoc info
    (if (string= thing (car inf-pilisp-eldoc-last-symbol))
        (cdr inf-pilisp-eldoc-last-symbol)
      (let ((arglists (inf-pilisp-arglists (substring-no-properties thing))))
        (when arglists
          (setq inf-pilisp-eldoc-last-symbol (cons thing arglists))
          arglists)))))

(defun inf-pilisp-eldoc ()
  "Backend function for eldoc to show argument list in the echo area."
  ;; todo: this never gets unset once connected and is a lie
  (when (and (inf-pilisp-connected-p)
             inf-pilisp-enable-eldoc
             ;; don't clobber an error message in the minibuffer
             (not (member last-command '(next-error previous-error))))
    (let* ((info (inf-pilisp-eldoc-info-in-current-sexp))
           (thing (car info))
           (value (inf-pilisp-eldoc-arglists thing)))
      (when value
        (format "%s: %s"
                (inf-pilisp-eldoc-format-thing thing)
                value)))))

(defun inf-pilisp-eldoc-setup ()
  "Turn on eldoc mode in the current buffer."
  (setq-local eldoc-documentation-function #'inf-pilisp-eldoc)
  (apply #'eldoc-add-command inf-pilisp-extra-eldoc-commands))

(defun inf-pilisp-display-version ()
  "Display the current `inf-pilisp' in the minibuffer."
  (interactive)
  (message "inf-pilisp (version %s)" inf-pilisp-version))

(defun inf-pilisp-select-target-repl ()
  "Find or select an ‘inf-pilisp’ buffer to operate on.

Useful for commands that can invoked outside of an ‘inf-pilisp’ buffer
\\(e.g. from a PiLisp buffer\\)."
  ;; if we're in a inf-pilisp buffer we simply return in
  (if (eq major-mode 'inf-pilisp-mode)
      (current-buffer)
    ;; otherwise we sift through all the inf-pilisp buffers that are available
    (let ((repl-buffers (cl-remove-if-not (lambda (buf)
                                            (with-current-buffer buf
                                              (eq major-mode 'inf-pilisp-mode)))
                                          (buffer-list))))
      (cond
       ((null repl-buffers) (user-error "No inf-pilisp buffers found"))
       ((= (length repl-buffers) 1) (car repl-buffers))
       (t (get-buffer (completing-read "Select target inf-pilisp buffer: "
                                       (mapcar #'buffer-name repl-buffers))))))))

(defun inf-pilisp--response-match-p (form match-p proc)
  "Send FORM and apply MATCH-P on the result of sending it to PROC.
Note that this function will add a \n to the end of the string
for evaluation, therefore FORM should not include it."
  (funcall match-p (inf-pilisp--process-response form proc nil)))

(provide 'inf-pilisp)

;; Local variables:
;; coding: utf-8
;; indent-tabs-mode: nil
;; End:

;;; inf-pilisp.el ends here
