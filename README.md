# inf-pilisp

This package provides basic interaction with a PiLisp subprocess (REPL).
It's based on `inf-clojure`.

`inf-pilisp` has two components - a REPL buffer (`inf-pilisp-mode`) and a REPL
interaction minor mode (`inf-pilisp-minor-mode`), which extends `pilisp-mode`
with commands to evaluate forms directly in the REPL.

## Overview

`inf-pilisp` aims to expose the extensive self-documenting features of
PiLisp REPLs via an Emacs package. `inf-pilisp` is extremely simple
and does not require special tooling. It supports any CLI PiLisp REPL.

`inf-pilisp` provides a set of essential features for interactive
PiLisp development:

* Enhanced REPL
* Interactive code evaluation
* Code completion
* Definition lookup
* Documentation lookup
* ElDoc
* Macroexpansion

## Rationale

`inf-pilisp`'s goal is to provide the simplest possible way to
interact with a PiLisp REPL from Emacs. In Emacs terminology
"inferior" process is a subprocess started by Emacs (it being the
"superior" process, of course).

`inf-pilisp` doesn't require much of setup, as at its core it simply
runs a terminal REPL process, pipes input to it, and processes its
output.

Functionality like code completion and eldoc is powered by evaluation
of predefined code snippets that provide the necessary results. As
different PiLisp REPLs have different capabilities, `inf-pilisp`
tracks the type of a REPL and invokes the right code for each REPL
type.

## Installation

**Note:** `inf-pilisp` requires Emacs 25 or newer.

This package is not yet published to any package repository.

1. Clone this repository.
1. Place it on your Emacs load path and configure (see below).

Here's an example of conditionally adding both `pilisp-mode` and
`inf-pilisp` to your load path (make sure to change the paths!) and
configuring (1) [smartparens] strict mode to be enabled by default and
(2) [cider] to be disabled, since its key bindings conflict with
`inf-pilisp`:

``` emacs-lisp
(when (file-exists-p "~/dev/pilisp/emacs-pilisp-mode")
  (add-to-list 'load-path "~/dev/pilisp/emacs-pilisp-mode")
  (require 'pilisp-mode)
  (add-hook 'pilisp-mode-hook 'smartparens-strict-mode))

(when (file-exists-p "~/dev/pilisp/emacs-inf-pilisp")
  (add-to-list 'load-path "~/dev/pilisp/emacs-inf-pilisp")
  (require 'cider)
  (require 'inf-pilisp)
  (autoload 'inf-pilisp "inf-pilisp" "Run an inferior PiLisp process" t)
  (defun pilisp/cider-mode-disable ()
    (cider-mode -1))
  (add-hook 'pilisp-mode-hook #'pilisp/cider-mode-disable)
  (add-hook 'pilisp-mode-hook #'inf-pilisp-minor-mode)
  (add-hook 'inf-pilisp-mode-hook 'smartparens-strict-mode))
```

With this configuration, open a PiLisp buffer and press `C-c C-z`, hit
<kbd>Enter</kbd> for the `pl` command, and you're up and running!

`inf-pilisp-minor-mode` will be auto-enabled for PiLisp source buffers
after you do `M-x inf-pilisp`. You can disable this behavior by
setting `inf-pilisp-auto-mode` to `nil`.

## Basic Usage

Just invoke `M-x inf-pilisp` or press `C-c C-z` within a PiLisp source
file. You should get a prompt with the supported REPL types (only one
for now), press <kbd>Enter</kbd> and the REPL should start and your
PiLisp buffer should be associated with it.

`inf-pilisp` aims to be very simple and offer tooling that the REPL
itself exposes. A few commands are:

- eval last sexp (`C-x C-e`)
- show arglists for function (`C-c C-a`)
- show binding documentation (`C-c C-d`)
- insert top level form into REPL (`C-c C-j d`)

For a list of all available commands in `inf-pilisp-mode` (a.k.a. the
REPL) and `inf-pilisp-minor-mode` you can either invoke `C-h f RET
inf-pilisp-mode` and `C-h f RET inf-pilisp-minor-mode` or simply
browse their menus.

Many `inf-pilisp-minor-mode` commands by default act on the symbol at
point. You can, however, change this behaviour by invoking such
commands with a prefix argument. For instance: `C-u C-c C-d` will ask
for the symbol you want to show the docstring for.

## Configuration

In the time-honoured Emacs tradition `inf-pilisp`'s behaviour is
extremely configurable.

You can set custom values to `inf-pilisp` variables on a per-project
basis using [directory
variables](https://www.gnu.org/software/emacs/manual/html_node/emacs/Directory-Variables.html)
or by setting them in in your init file.

You can see all the configuration options available using the command
`M-x customize-group RET inf-pilisp`.

### Startup

While `inf-pilisp` is capable of starting many common REPLs out of the
box, it's fairly likely you will want to set some custom REPL startup
command (e.g. because you need to include some `tools.deps` profile)
and the REPL type that goes with it. This is most easily achieved with
the following `.dir-locals.el`:

```emacs-lisp
((nil
  (inf-pilisp-custom-startup . "pl some args")
  (inf-pilisp-custom-repl-type . pilisp-custom)))
```

**Note:** This file has to be in the directory in which you're
invoking `inf-pilisp` or a parent directory.

There are two important configuration variables here:

1. `inf-pilisp-custom-startup`: Which startup command to use so
   inf-pilisp can run the inferior PiLisp process (REPL).
2. `inf-pilisp-custom-repl-type`: The type of the REPL started by the
   above command (e.g. `pilisp`).

If these are set and you wish to prevent inf-pilisp from using them,
use a prefix arg when invoking `inf-pilisp` (`C-u M-x inf-pilisp`).

### REPL Features

The supported REPL-features are in an alist called
`inf-pilisp-repl-features` and it has the following shape:

```emacs-lisp
(defvar inf-pilisp-repl-features
  '((pilisp . ((load . "(repl/load-file %s)")
               (doc . "(doc %s)")
               (arglists . "(arglists %s)")
               (macroexpand . "(macroexpand '%s)")
               (macroexpand-1 . "(macroexpand-1 '%s)")))))
```

If you want to add a new REPL type, just do something like:

``` emacs-lisp
(add-to-list 'inf-pilisp-repl-features
             (cons new-repl-type '((doc . "(myrepl/doc-command %s")
                                   (source . "...")
                                   ...)))
```

The `inf-pilisp-repl-features` data structure is just an alist of
alists, so you can manipulate it in numerous ways.

If you want to update a specific form there is a function
`inf-pilisp-update-repl-feature` which can be used like so:

```emacs-lisp
(inf-pilisp-update-feature 'pilisp 'completion "(my-completions \"%s\")")
```

#### Caveats

As `inf-pilisp` is built on top of `inf-clojure` which is built on top
of `comint`, it has all the usual comint limitations - namely it can't
handle well some fancy terminal features (e.g. ANSI colours).  In
general the "dumber" your terminal REPL is, the better.

If you decide _not_ to use the socket REPL, it is highly recommended
you disable output coloring and/or `readline` facilities: `inf-pilisp`
does not filter out ASCII escape characters at the moment and will not
behave correctly.

#### Multiple Process Support

To run multiple PiLisp processes, you start the first up with
`inf-pilisp`.  It will be in a buffer named `*inf-pilisp*`.  Rename
this buffer with `rename-buffer`.  You may now start up a new process
with another `inf-pilisp`.  It will be in a new buffer, named
`*inf-pilisp*`.  You can switch between the different process buffers
with `switch-to-buffer`.

**Note:** If you're starting `inf-pilisp` within a PiLisp project
directory the name of the project will be incorporated into the name
of the REPL buffer
- e.g. `*inf-pilisp my-project*`.

Commands that send text from source buffers to PiLisp processes (like
`inf-pilisp-eval-defun` or `inf-pilisp-show-arglists`) have to choose
a process to send to, when you have more than one PiLisp process
around. This is determined by the global variable `inf-pilisp-buffer`.

Suppose you have three inferior PiLisps running:

```
Buffer              Process
------              -------
foo                 inf-pilisp
bar                 inf-pilisp<2>
*inf-pilisp*        inf-pilisp<3>
```

If you do a `inf-pilisp-eval-defun` command on some PiLisp source
code, what process do you send it to?

- If you're in a process buffer (foo, bar, or `*inf-pilisp*`),
  you send it to that process.
- If you're in some other buffer (e.g., a source file), you
  send it to the process attached to buffer `inf-pilisp-buffer`.

This process selection is performed by function `inf-pilisp-proc`.
Whenever `inf-pilisp` fires up a new process, it resets
`inf-pilisp-buffer` to be the new process's buffer.  If you only run
one process, this does the right thing.  If you run multiple
processes, you might need to change `inf-pilisp-buffer` to
whichever process buffer you want to use.

You can use the helpful function `inf-pilisp-set-repl`. If called in
an `inf-pilisp` REPL buffer, it will assign that buffer as the current
REPL (`(setq inf-pilisp-buffer (current-buffer)`). If you are not in
an `inf-pilisp` REPL buffer, it will offer a choice of acceptable
buffers to set as the REPL buffer. If called with a prefix, it will
always give the list even if you are currently in an acceptable REPL
buffer.

**Tip:** Renaming buffers will greatly improve the functionality of
this list; the list "project-1: pilisp repl", "project-2: pilisp repl"
is far more understandable than "inf-pilisp", "inf-pilisp<2>".

#### ElDoc

`eldoc-mode` is supported in PiLisp source buffers and
`*inferior-pilisp*` buffers which are running a PiLisp REPL.

When ElDoc is enabled and there is an active REPL, it will show the
argument list of the function call you are currently editing in the
echo area. It accomplishes this by evaluating forms to get the
metadata for the bindings under your cursor. One side effect of this
is that it can mess with bindings like `*1` and `*2`. You can disable
inf-pilisp's Eldoc functionality with `(setq inf-pilisp-enable-eldoc
nil)`.


ElDoc should be enabled by default in Emacs 26.1+. If it is not active
by default, you can activate ElDoc with `M-x eldoc-mode` or by adding
the following to you Emacs config:

```emacs-lisp
(add-hook 'pilisp-mode-hook #'eldoc-mode)
(add-hook 'inf-pilisp-mode-hook #'eldoc-mode)
```

## Troubleshooting

### REPL not responsive in Windows OS

In Windows, the REPL is not returning anything. For example, type `(+
1 1)` and press `ENTER`, the cursor just drops to a new line and
nothing is shown.

The explanation of this problem and solution can be found
[here](https://groups.google.com/forum/#!topic/leiningen/48M-xvcI2Ng).

The solution is to create a file named `.jline.rc` in your `$HOME`
directory and add this line to that file:

```
jline.terminal=unsupported
```

### Log process activity

Standard Emacs debugging turns out to be difficult when an
asynchronous process is involved. In this case try to enable logging:

```emacs-lisp
(setq inf-pilisp-log-activity t)
```

This creates `.inf-pilisp.log` in the project directory so that you
can `tail -f` on it.

## License

Copyright © 2023 Daniel Gregoire

Distributed under the GNU General Public License; type <kbd>C-h
C-c</kbd> in Emacs to view it or see the [LICENSE](./LICENSE) file.

### inf-clojure

The entire implementation has been adapted from the [inf-clojure][]
project. Its copyright and license are:

Copyright © 2014-2022 Bozhidar Batsov and contributors.

Distributed under the GNU General Public License; type <kbd>C-h
C-c</kbd> to view it.

[inf-clojure]: https://github.com/clojure-emacs/inf-clojure
[smartparens]: https://github.com/Fuco1/smartparens
