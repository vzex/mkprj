;;; mk-project.el ---  Lightweight project handling

;; This program has been modified by vzex(vzex@163.com)
;; #Changes##################################
;; file_index and project_tags work in background,without effect current
;; project file changes:
;; project find file:"xxx.*yyy\.cpp" => "xxx*yyy.cpp"
;; remove tags and index file keywords in project-def,both will be set by default in the project basedir
;; add subdir keyword,if set,project will only search the dirs in subdir
;; remove ingore-pattern,only the src-pattern affects
;; add project-find-tag function for key-binding
;; project-find-file:use hash map to replace the file buffer search
;; add much more features to find out...
;;
;; fix the bug when find file in proj,if the matches cnt is one,the file cannot be opened correctly.
;; 
;; after generated the file_index,then the tags will be generated with the file list in file_index
;; all the project operations,like grep,find file,gen tags,are depend on the file_index.So without execute "find" command every time when doing these operations,it will be faster!
;; need shell commands:find,grep,xargs,cat,sed. Please make sure you have all of the shell commands in system
;; #Changes##################################
;;(load-file "~/.emacs.d/mk-prj.el")
;;(project-init)

;; new prj-file-example
;;(project-def "p"
;;      '((basedir          "f:/trunk/program")
;;        (src-patterns     ("*.lua"))
;;        (subdir     ("game/" "etc/"))
;;        (vcs              svn)
;;        (open-file-cache t)
;;		  (open-file-cache-maxn 10)
;;        (idle-index t)
;;        (pre-startup-hook ecb-activate)
;;        (startup-hook project-index)
;;        ))
;;
;; Copyright (C) 2010  Matt Keller <mattkeller at gmail dot com>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Quickly switch between projects and perform operations on a
;; per-project basis. A 'project' in this sense is a directory of
;; related files, usually a directory of source files. Projects are
;; defined in pure elisp with the 'project-def' function. No
;; mk-project-specific files are required in the project's base
;; directory.

;; More information about this library, including the most recent
;; version and a comprehensive README, is available at
;; http://github.com/mattkeller/mk-project

;;; Code:

(require 'grep)
(require 'thingatpt)
(require 'cl)

(defvar mk-proj-version "extra-1.0"
  "As tagged at http://github.com/mattkeller/mk-project/tree/master")

;; ---------------------------------------------------------------------
;; Project Variables
;;
;; These variables are set when a project is loaded and nil'd out when
;; unloaded. These symbols are the same as defined in the 2nd parameter
;; to project-def except for their "mk-proj-" prefix.
;; ---------------------------------------------------------------------

(defvar mk-proj-find-cmd "find")
(defvar mk-proj-grep-cmd "grep")
(defvar mk-proj-idle-timer nil)

(defvar mk-proj-name nil
  "Name of the current project. Required. First argument to project-def.")

(defvar mk-proj-basedir nil
  "Base directory of the current project. Required. Value is expanded with
expand-file-name. Example: ~me/my-proj/.")


(defvar mk-proj-subdir nil
  "if not nil ,search the subdir list from basedir,Otherwise,search all subdir from basedir")

(defvar mk-proj-idle-index nil)
(defvar mk-proj-default-config-dir "~/.emacs.d/mkprjs/")
(defvar mk-proj-src-patterns nil
  "List of shell patterns to include in the TAGS file. Optional. Example:
'(\"*.java\" \"*.jsp\").

This value is not used when `mk-proj-src-find-cmd' is set.")

(defvar mk-proj-ack-args nil
  "String of arguments to pass to the `ack' command. Optional.
Example: \"--java\".")

(defvar mk-proj-vcs nil
  "When set to one of the VCS types in `mk-proj-vcs-path', grep
and index commands will ignore the VCS's private files (e.g.,
.CVS/). Example: 'git.

This value is not used in indexing when `mk-proj-index-find-cmd'
is set -- or in grepping when `mk-proj-grep-find-cmd' is set.")

; TODO: support multiple tags file via tags-table-list
(defvar mk-proj-tags-file nil
  "Path to the TAGS file for this project. Optional. Use an absolute path,
not one relative to basedir. Value is expanded with expand-file-name.")

(defvar mk-proj-tags-file-bak nil)

(defvar mk-proj-compile-cmd nil
  "Command to build the entire project. Can be either a string specifying 
a shell command or the name of a function. Optional. Example: make -k.")

(defvar mk-proj-startup-hook nil
  "Hook function to run after the project is loaded. Optional. Project
variables (e.g. mk-proj-basedir) will be set and can be referenced from this
function.")
(defvar mk-proj-pre-startup-hook nil)
(defvar mk-proj-shutdown-hook nil
  "Hook function to run after the project is unloaded. Optional.  Project
variables (e.g. mk-proj-basedir) will still be set and can be referenced
from this function.")

(defvar mk-proj-file-list-map nil)
(defvar mk-proj-file-list-cache nil
  "Cache *file-index* buffer to this file. Optional. If set, the *file-index*
buffer will take its initial value from this file and updates to the buffer
via 'project-index' will save to this file. Value is expanded with
expand-file-name.")

(defvar mk-proj-open-file-cache nil)
(defvar mk-proj-open-file-cache-maxn nil)
(defvar mk-proj-open-files-cache nil
  "Cache the names of open project files in this file. Optional. If set,
project-load will open all files listed in this file and project-unload will
write all open project files to this file. Value is expanded with
expand-file-name.")

(defvar mk-proj-src-find-cmd nil
  "Specifies a custom \"find\" command to locate all files to be
included in the TAGS file (see `project-tags'). Optional. The
value is either a string or a function of one argument that
returns a string. The argument to the function will be the symbol
\"'src\".

If non-null (or if the function returns non-null), the custom
find command will be used and the `mk-proj-src-patterns' and
`mk-proj-vcs' settings are ignored when finding files to include
in TAGS.")

(defvar mk-proj-grep-find-cmd nil
  "Specifies a custom \"find\" command to use as the default when
running `project-grep'. Optional. The value is either a string or
a function of one argument that returns a string. The argument to
the function will be the symbol \"'grep\". The string or returned
string MUST use find's \"-print0\" argument as the results of
this command are piped to \"xargs -0 ...\".

If non-null (or if the function returns non-null), the custom
find command will be used and the `' and
`mk-proj-vcs' settings will not be used in the grep command.

The custom find command should use \".\" (current directory) as
the path that find starts at -- this will allow the C-u argument
to `project-grep' to run the command from the current buffer's
directory.")

(defvar mk-proj-index-find-cmd nil
  "Specifies a custom \"find\" command to use when building an
listing of all files in the project (to be used by
`project-find-files'). Optional. The value is either a string or a
function of one argument that returns a string. The argument to
the function will be the symbol \"'index\".

If non-null (or if the function returns non-null), the custom
find command will be used and the `' and
`mk-proj-vcs' settings are not used when in the grep command.")
(defvar mk-proj-index-running nil)
(defvar mk-proj-tag-running nil)
(defconst mk-proj-fib-name "*file-index*"
  "Buffer name of the file-list cache. This buffer contains a
list of all the files under the project's basedir (minus those
matching ignore-patterns) or, if index-find-cmd is set, the list
of files found by calling the custom find command.  The list is
used by `project-find-files' to quickly locate project files.")

(defconst mk-proj-vcs-path '((git . "'*/.git/*'")
                             (cvs . "'*/.CVS/*'")
                             (svn . "'*/.svn/*'")
                             (bzr . "'*/.bzr/*'")
                             (hg  . "'*/.hg/*'")
                             (darcs . "'*/_darcs/*'"))
  "When `mk-proj-vcs' is one of the VCS types listed here, ignore
the associated paths when greping or indexing the project. This
value is not used if a custom find command is set in
`mk-proj-grep-find-cmd' or `mk-proj-index-find-cmd'")

(defconst mk-proj-proj-vars '(mk-proj-name
                              mk-proj-basedir
                              mk-proj-subdir
                              mk-proj-src-patterns
                              mk-proj-idle-index
                              mk-proj-ack-args
                              mk-proj-vcs
                              mk-proj-tags-file
                              mk-proj-compile-cmd
                              mk-proj-startup-hook
							  mk-proj-pre-startup-hook
                              mk-proj-shutdown-hook
                              mk-proj-file-list-cache
                              mk-proj-open-file-cache
							  mk-proj-open-file-cache-maxn
                              mk-proj-src-find-cmd
                              mk-proj-grep-find-cmd
                              mk-proj-index-find-cmd)
  "List of all our project settings")

;; ---------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------

(defgroup mk-project nil
  "A programming project management library."
  :group 'tools)

(defcustom mk-proj-ack-respect-case-fold t
  "If on and case-fold-search is true, project-ack will ignore case by passing \"-i\" to ack."
  :type 'boolean
  :group 'mk-project)

(defcustom mk-proj-use-ido-selection nil
  "If ido-mode is available, use ido selection where appropriate."
  :type 'boolean
  :group 'mk-project)

(defcustom mk-proj-ack-cmd (if (eq system-type 'windows-nt) "ack.pl" "ack")
  "Name of the ack program to run. Defaults to \"ack\" (or \"ack.pl\" on Windows)."
  :type 'string
  :group 'mk-project)

(defcustom mk-proj-menu-on t
  "If non-nil, define the 'mk-project' menu in the menu-bar at
load time. See also `project-menu-remove'."
  :type 'boolean
  :group 'mk-project)

;; ---------------------------------------------------------------------
;; Utils
;; ---------------------------------------------------------------------

(defun mk-proj-replace-tail (str tail-str replacement)
  (if (string-match (concat tail-str "$")  str)
    (replace-match replacement t t str)
    str))

(defun mk-proj-assert-proj ()
  (unless mk-proj-name
    (error "No project is set!")))

(defun mk-proj-maybe-kill-buffer (bufname)
  (message "maybe kill %s" bufname)
  (let ((b (get-buffer bufname)))
    (when b (kill-buffer b))))

(defun mk-proj-get-vcs-path ()
  (if mk-proj-vcs
      (cdr (assoc mk-proj-vcs mk-proj-vcs-path))
    nil))

(defun mk-proj-has-univ-arg ()
  (eql (prefix-numeric-value current-prefix-arg) 4))

(defun mk-proj-names ()
  (let ((names nil))
    (maphash (lambda (k v) (add-to-list 'names k)) mk-proj-list)
    names))

(defun mk-proj-use-ido ()
  (and (boundp 'ido-mode) mk-proj-use-ido-selection))

(defun mk-proj-find-cmd-val (context)
  (let ((cmd (ecase context
               ('src   mk-proj-src-find-cmd)
               ('grep  mk-proj-grep-find-cmd)
               ('index mk-proj-index-find-cmd))))
    (if cmd
        (cond ((stringp cmd) cmd)
              ((functionp cmd) (funcall cmd context))
              (t (error "find-cmd is neither a string or a function")))
      nil)))

(defun mk-proj-filter (condp lst)
  (delq nil
        (mapcar (lambda (x) (and (funcall condp x) x)) lst)))

;; ---------------------------------------------------------------------
;; Project Configuration
;; ---------------------------------------------------------------------

(defvar mk-proj-list (make-hash-table :test 'equal))

(defun mk-proj-find-config (proj-name)
  (gethash proj-name mk-proj-list))

(defun project-def (proj-name config-alist)
  "Associate the settings in <config-alist> with project <proj-name>"
  (puthash proj-name config-alist mk-proj-list))
(defun project-init ()
  (setq mk-proj-list (make-hash-table :test 'equal))
  (let ((filelist (directory-files mk-proj-default-config-dir nil "^\\([^.]\\|\\.[^.]\\|\\.\\..\\)")))
	(dolist (file filelist) (load-file (concat mk-proj-default-config-dir "/" file))
					  ))
  )
(defun project-edit ()
  "Edit project file"
  (interactive)
  	(let ((name (completing-read "Project Name: " (mk-proj-names))))
	  (find-file (concat mk-proj-default-config-dir "/" name ".el"))
	  )
	)
(defun mk-proj-defaults ()
  "Set all default values for project variables"
  (dolist (var mk-proj-proj-vars)
    (set var nil)))

(defun mk-proj-load-vars (proj-name proj-alist)
  "Set project variables from proj-alist"
  (cl-labels ((config-val (key)
            (if (assoc key proj-alist)
                (car (cdr (assoc key proj-alist)))
              nil))
           (maybe-set-var (var &optional fn)
             (let ((proj-var (intern (concat "mk-proj-" (symbol-name var))))
                   (val (config-val var)))
               (when val (setf (symbol-value proj-var) (if fn (funcall fn val) val))))))
    (mk-proj-defaults)
    ;; required vars
    (setq mk-proj-name (file-name-nondirectory proj-name))
    (setq mk-proj-basedir (file-name-as-directory (expand-file-name (config-val 'basedir))))
    ;; optional vars
    (dolist (v '(src-patterns ack-args vcs subdir open-file-cache open-file-cache-maxn
                 compile-cmd src-find-cmd grep-find-cmd idle-index
                 index-find-cmd startup-hook pre-startup-hook shutdown-hook))
      (maybe-set-var v))
    (setq mk-proj-tags-file (concat mk-proj-basedir mk-proj-name "_tags"))
    (setq mk-proj-file-list-cache  (concat mk-proj-basedir mk-proj-name "_index"))
 ;   (maybe-set-var 'open-file-cache #'expand-file-name)
    (if (eq nil mk-proj-open-file-cache) nil (setq mk-proj-open-files-cache (concat mk-proj-basedir mk-proj-name "_cache")))
    ))
(defun project-delete (&optional name)
  "Delete a project file"
  (interactive)
  (catch 'project-delete
	(let ((name (or name (completing-read "Project Name: " (mk-proj-names))))
		  )
	(setq tempname (concat mk-proj-default-config-dir "/" name ".el"))
	(if (file-exists-p tempname) 
		(delete-file tempname))
	(project-init)
	))
  )
(defun project-create (&optional name)
  "Create a project file"
  (interactive)
  (catch 'project-create
	(let
		((name (or name (read-string "Project Name: ")))
		 (basedir (read-file-name "Basic dir: "))
		 (filter (read-string "File Filter(ex:*.lua *.h *.cpp): "))
		 (subdir (read-string "Sub Dir(ex:src/ include/):if empty, search all dirs "))
		 (vcs (completing-read "svn or git?: " (list "svn" "git")))
		 (openfilecache (completing-read "Need Cache OpenFile?: " (list "y" "n")))
		 (idleindex (completing-read "Need auto index file when idle?: " (list "y" "n")))
		 (prehook (completing-read "PreStartUpHookFunction(ex:ecb-activate): " (list "ecb-activate")))
		 (startuphook (completing-read "StartUpHookFunction(ex:project-index): " (list "project-index")))
		 )
	  (if (file-exists-p mk-proj-default-config-dir) ()
		(make-directory mk-proj-default-config-dir)
      )
	  
	  (with-temp-buffer
		(if (string-equal openfilecache "y") (setq cachen (read-number "Max Cache File Num:(<=0 means no limit)")) (setq cachen 0))
	    (insert "(project-def \"" name "\"\n" )
		(insert "\t'((basedir\t\"" basedir "\")\n")
		(if (not (string-equal filter "")) (insert "\t(src-patterns\t(" (mapconcat (function (lambda (x) (format "\"%s\"" x))) (split-string filter " " t " ") " ") "))\n"))
		(if (not (string-equal subdir "")) (insert "\t(subdir\t(" (mapconcat (function (lambda (x) (format "\"%s/\"" x))) (split-string subdir " " t " ") " ") "))\n"))
		(if (string-equal vcs "y") (insert "\t(vcs\t" vcs ")\n"))
		(if (string-equal openfilecache "y") (insert "\t(open-file-cache\tt)\n"))
		(if (> cachen 0) (insert (concat"\t(open-file-cache-maxn\t" (format "%s" cachen) ")\n")))
		(if (string-equal idleindex "y") (insert "\t(idle-index\tt)\n"))
		(if (not (string-equal prehook "")) (insert "\t(pre-startup-hook\t" prehook ")\n"))
		(if (not (string-equal startuphook "")) (insert "\t(startup-hook\t" startuphook ")\n"))
		(insert "))")
		(setq tempname (concat mk-proj-default-config-dir "/" name ".el"))
		(if (file-writable-p tempname)
			(progn
			  (write-region (point-min)
							(point-max)
							tempname)
			  (message "Wrote Project file to %s" tempname))
		  (message "Cannot write to %s" tempname)))
	  (project-init)
	  )
	)
)
(defun project-load (&optional name)
  "Load a project's settings."
  (interactive)
  (catch 'project-load
    (let ((oldname mk-proj-name)
          (name (or name
                    (if (mk-proj-use-ido)
                        (ido-completing-read "Project Name (ido): "
                                             (mk-proj-names))
                      (completing-read "Project Name: " (mk-proj-names))))))
      (unless (string= oldname name)
        (project-unload))
      (let ((proj-config (mk-proj-find-config name)))
        (if proj-config
            (mk-proj-load-vars name proj-config)
          (message "Project %s does not exist!" name)
          (throw 'project-load t)))
      (when (not (file-directory-p mk-proj-basedir))
        (message "Base directory %s does not exist!" mk-proj-basedir)
        (throw 'project-load t))
      (when (and mk-proj-vcs (not (mk-proj-get-vcs-path)))
        (message "Invalid VCS setting!")
        (throw 'project-load t))
      (message "Loading project %s ..." name)
      (cd mk-proj-basedir)
	  (when mk-proj-pre-startup-hook
        (run-hooks 'mk-proj-pre-startup-hook))
      (mk-proj-tags-load)
      (mk-proj-fib-init)
      (mk-proj-visit-saved-open-files)
      (add-hook 'kill-emacs-hook 'mk-proj-kill-emacs-hook)
      (when mk-proj-startup-hook
        (run-hooks 'mk-proj-startup-hook))
      (if mk-proj-idle-index
        (setq mk-proj-idle-timer (run-with-idle-timer 120 t 'project-index))
		nil
        )

      (message "Loading project %s done" name))))

(defun mk-proj-kill-emacs-hook ()
  "Ensure we save the open-files-cache info on emacs exit"
  (when (and mk-proj-name mk-proj-open-files-cache)
    (mk-proj-save-open-file-info)))

(defun project-unload ()
  "Unload the current project's settings after running the shutdown hook."
  (interactive)
  (when mk-proj-name
    (message "Unloading project %s" mk-proj-name)
    (mk-proj-tags-clear)
    (mk-proj-fib-clear)
    (mk-proj-maybe-kill-buffer mk-proj-fib-name)
    (if mk-proj-idle-index
      (cancel-timer mk-proj-idle-timer)
	  nil
      )

    (mk-proj-save-open-file-info)
    (when (and (mk-proj-buffers)
               (y-or-n-p (concat "Close all " mk-proj-name " project files? "))
      (project-close-files)))
    (when mk-proj-shutdown-hook (run-hooks 'mk-proj-shutdown-hook)))
  (mk-proj-defaults)
  (message "Project settings have been cleared"))

(defun project-close-files ()
  "Close all unmodified files that reside in the project's basedir"
  (interactive)
  (mk-proj-assert-proj)
  (let ((closed nil)
        (dirty nil)
        (basedir-len (length mk-proj-basedir)))
    (dolist (b (mk-proj-buffers))
      (cond
       ((buffer-modified-p b)
        (push (buffer-name) dirty))
       (t
        (kill-buffer b)
        (push (buffer-name) closed))))
    (message "Closed %d buffers, %d modified buffers where left open"
             (length closed) (length dirty))))

(defun mk-proj-buffer-name (buf)
  "Return buffer's name based on filename or dired's location"
  (let ((file-name (or (buffer-file-name buf)
                       (with-current-buffer buf list-buffers-directory))))
    (if file-name
        (expand-file-name file-name)
      nil)))

(defun mk-proj-buffer-p (buf)
  "Is the given buffer in our project based on filename? Also detects dired buffers open to basedir/*"
  (let ((file-name (mk-proj-buffer-name buf)))
    (if (and file-name
             (string-match (concat "^" (regexp-quote mk-proj-basedir) ".+") file-name)
			 (not (string-equal (concat mk-proj-basedir mk-proj-name "_index") file-name))
			 (not (string-equal (concat mk-proj-basedir mk-proj-name "_tags") file-name))
			 (not (string-equal (concat mk-proj-basedir mk-proj-name "_cache") file-name))
			 )
        t
      nil)))

(defun mk-proj-buffers ()
  "Get a list of buffers that reside in this project's basedir"
  (let ((buffers nil))
    (dolist (b (buffer-list))
      (when (mk-proj-buffer-p b) (push b buffers)))
    buffers))

(defun project-status ()
 "View project's variables."
 (interactive)
 (if mk-proj-basedir
   (let ((b (get-buffer-create "*project-status*")))
     (with-current-buffer b
       (kill-region (point-min) (point-max))
       (dolist (v mk-proj-proj-vars)
         (insert (format "%-24s = %s\n" v (symbol-value v)))))
     (when (not (eq b (current-buffer)))
       (switch-to-buffer-other-window b)))
   (message "No project loaded.")))

;; ---------------------------------------------------------------------
;; Save/Restore open files
;; ---------------------------------------------------------------------
(defun _sublist (list from to)
  "Return a sublist of LIST, from FROM to TO.
Counting starts at 0. Like `substring' but for lists."
  (let (rtn (c from))
    (setq list (nthcdr from list))
    (while (and list (< c to))
      (push (pop list) rtn)
      (setq c (1+ c)))
    (nreverse rtn)))
(defun mk-proj-save-open-file-info ()
  "Write the list of `files' to a file"
  (when mk-proj-open-files-cache
    (with-temp-buffer
	  (if mk-proj-open-file-cache-maxn (dolist (f (reverse (_sublist (mapcar (lambda (b) (mk-proj-buffer-name b)) (reverse (mk-proj-buffers))) 0 mk-proj-open-file-cache-maxn)))
        (when f
          (unless (string-equal mk-proj-tags-file f)
            (insert f "\n"))))
		(dolist (f (mapcar (lambda (b) (mk-proj-buffer-name b)) (mk-proj-buffers)))
        (when f
          (unless (string-equal mk-proj-tags-file f)
            (insert f "\n"))))
		)
      (if (file-writable-p mk-proj-open-files-cache)
          (progn
            (write-region (point-min)
                          (point-max)
                          mk-proj-open-files-cache)
            (message "Wrote open files to %s" mk-proj-open-files-cache))
        (message "Cannot write to %s" mk-proj-open-files-cache)))))

(defun mk-proj-visit-saved-open-files ()
  (when mk-proj-open-files-cache
    (when (file-readable-p mk-proj-open-files-cache)
      (message "Reading open files from %s" mk-proj-open-files-cache)
      (with-temp-buffer
        (insert-file-contents mk-proj-open-files-cache)
		(let ((_filelist ()))
		  (goto-char (point-min))
		  (while (not (eobp))
			(let ((start (point)))
			  (while (not (eolp)) (forward-char)) ; goto end of line
			  (let ((line (buffer-substring start (point))))
				(setq _filelist (append _filelist (list line)))
				))
			(forward-line))
		  (dolist (f _filelist)
			(message "Attempting to open %s" f)
			(find-file f)
			))
		  ))))

;; ---------------------------------------------------------------------
;; Etags
;; ---------------------------------------------------------------------

(defun mk-proj-tags-load ()
  "Load TAGS file (if tags-file set)"
  ;(mk-proj-tags-clear)
  (setq tags-file-name  mk-proj-tags-file
        tags-table-list nil)
  (when (and mk-proj-tags-file (file-readable-p mk-proj-tags-file))
    (visit-tags-table mk-proj-tags-file)))

(defun mk-proj-tags-clear ()
  "Clear the TAGS file (if tags-file set)"
  (when (and mk-proj-tags-file (get-file-buffer mk-proj-tags-file))
    (mk-proj-maybe-kill-buffer (get-file-buffer mk-proj-tags-file)))
  (setq tags-file-name  nil
        tags-table-list nil))

(defun mk-proj-etags-cb (process event)
  "Visit tags table when the etags process finishes."
  (message "Etags process %s received event %s" process event)
  (kill-buffer (get-buffer "*etags*"))
  (setq mk-proj-tag-running nil)
  (cond
   ((string= event "finished\n")
    (mk-proj-tags-clear)
    (if (file-exists-p mk-proj-tags-file) 
      (delete-file mk-proj-tags-file))
    (rename-file mk-proj-tags-file-bak mk-proj-tags-file)
    (mk-proj-tags-load)
    (message "Refreshing TAGS file %s...done" mk-proj-tags-file))
   (t (message "Refreshing TAGS file %s...failed" mk-proj-tags-file))))

(defun project-tags ()
  "Regenerate the project's TAG file. Runs in the background."
  (interactive)
  (mk-proj-assert-proj)
  (if mk-proj-tag-running
	  (error "tag is processing!")
	  )
  (if mk-proj-tags-file
      (let* ((tags-file-name (file-name-nondirectory mk-proj-tags-file))
             (default-directory mk-proj-basedir)
             (tags-file-bak (concat default-directory "~" tags-file-name))
              (etags-cmd (concat "cat " mk-proj-file-list-cache "|sed 's/ /\\\\\\ /g'|etags -o " tags-file-bak " -"))
             (proc-name "etags-process"))
        (setq  mk-proj-tags-file-bak tags-file-bak)
        (message "project-tags default-dir %s" default-directory)
        (message "project-tags cmd \"%s\"" etags-cmd)
        (message "Refreshing TAGS file %s..." mk-proj-tags-file)
		(setq mk-proj-tag-running t)
        (start-process-shell-command proc-name "*etags*" etags-cmd)
        (set-process-sentinel (get-process proc-name) 'mk-proj-etags-cb))
    (message "mk-proj-tags-file is not set")))

(defun mk-proj-find-cmd-src-args (src-patterns)
  "Generate the ( -name <pat1> -o -name <pat2> ...) pattern for find cmd"
  (if src-patterns
      (let ((name-expr " \\("))
        (dolist (pat src-patterns)
          (setq name-expr (concat name-expr " -name \"" pat "\" -o ")))
        (concat (mk-proj-replace-tail name-expr "-o " "") "\\) "))
    ""))

(defun mk-proj-find-cmd-match-args (ignore-patterns)
  "Generate the  ( -name <pat1> -o -name <pat2> ...) pattern for find cmd"
  (if ignore-patterns
      (concat " " (mk-proj-find-cmd-src-args ignore-patterns))
    ""))

;; ---------------------------------------------------------------------
;; Grep
;; ---------------------------------------------------------------------

(defun project-grep (confirm)
  "Run find-grep on the project's basedir, excluding files in 
, tag files, etc.

If the phrase argument is not included, it will prompt for a
search phrase.  If the from-current-dir argument is true, or with
C-u prefix, start from the current directory."
  (interactive "p")
  (mk-proj-assert-proj)
  (if (not (and mk-proj-file-list-cache
           (file-readable-p mk-proj-file-list-cache)))
    (error (concat "No fileindex " mk-proj-file-list-cache "exist!"))
    )

  (let* ((wap (word-at-point))
         (regex (or nil
                    (if wap (read-string (concat "Grep project for (default \"" wap "\"): ") nil nil wap)
                      (read-string "Grep project for: "))))
         (grep-cmd (concat mk-proj-grep-cmd " -i -n \"" (replace-regexp-in-string "\"" "\\\\\"" regex) "\""))
         (default-directory mk-proj-basedir)
         (whole-cmd (concat "cat " mk-proj-file-list-cache "|sed 's/ /\\\\\\ /g'| xargs " grep-cmd))
         (confirmed-cmd (if (eq confirm 4) (read-string "Grep command: " whole-cmd nil whole-cmd)  whole-cmd))
		 )
      (message "project-grep cmd: \"%s\"" confirmed-cmd)
      (grep-find confirmed-cmd))
    )

;; ---------------------------------------------------------------------
;; Ack (betterthangrep.com)
;; ---------------------------------------------------------------------

(define-compilation-mode ack-mode "Ack" "Ack compilation mode." nil)

(defvar mk-proj-ack-default-args "--nocolor --nogroup")

(defun mk-proj-ack-cmd (regex)
  "Generate the ack command string given a regex to search for."
  (concat mk-proj-ack-cmd " "
          mk-proj-ack-default-args " "
          (if (and mk-proj-ack-respect-case-fold case-fold-search) "-i " "")
          mk-proj-ack-args " "
          regex))

(defun project-ack (&optional phrase from-current-dir)
  "Run ack from project's basedir, using the `ack-args' configuration.
With C-u prefix, start ack from the current directory."
  (interactive)
  (mk-proj-assert-proj)
  (let* ((wap (word-at-point))
         (regex (or phrase
                    (if wap (read-string (concat "Ack project for (default \"" wap "\"): ") nil nil wap)
                  (read-string "Ack project for: "))))
         (whole-cmd (mk-proj-ack-cmd regex))
         (confirmed-cmd (read-string "Ack command: " whole-cmd nil whole-cmd))
         (default-directory (file-name-as-directory
                             (if (or from-current-dir (mk-proj-has-univ-arg))
                                 default-directory
                               mk-proj-basedir))))
    (compilation-start confirmed-cmd 'ack-mode)))

;; ---------------------------------------------------------------------
;; Compile
;; ---------------------------------------------------------------------

(defun project-compile (&optional opts)
 "Run the compile command (string or function) for this project."
 (interactive)
 (mk-proj-assert-proj)
 (let ((default-directory mk-proj-basedir))
   (cond ((stringp mk-proj-compile-cmd)
          (when (and (null opts) (called-interactively-p))
            (setq opts (read-string "Compile options: ")))
          (compile (concat mk-proj-compile-cmd " " opts)))
         ((fboundp mk-proj-compile-cmd)
          (cond ((commandp mk-proj-compile-cmd)
                 (call-interactively mk-proj-compile-cmd))
                (opts
                 (funcall mk-proj-compile-cmd opts))
                (t (funcall mk-proj-compile-cmd))))
         (t (message "No compile command defined.")))))

;; ---------------------------------------------------------------------
;; Dired
;; ---------------------------------------------------------------------

(defun project-dired ()
  "Open dired in the project's basedir (or jump to the existing dired buffer)"
  (interactive)
  (mk-proj-assert-proj)
  (dired mk-proj-basedir))

;; ---------------------------------------------------------------------
;; Find-file
;; ---------------------------------------------------------------------
(defun getLines (fileName)
  (with-temp-buffer 
    (insert-file-contents fileName)
    (split-string (buffer-string) "\n" t))
  )
(defun load-project-index ()
  (mk-proj-maybe-kill-buffer (file-name-nondirectory mk-proj-file-list-cache))
  (let ((lines (getLines mk-proj-file-list-cache)))
    (message "load index %s" mk-proj-file-list-cache)
    (setq mk-proj-file-list-map (make-hash-table :test 'equal))
    (dolist (line lines)
       (puthash line t mk-proj-file-list-map)
        ;(message "load file:%s" line)
       )
     (message "load project-index from file ok")
	 (mk-proj-maybe-kill-buffer (file-name-nondirectory mk-proj-file-list-cache))
     )
  )
(defun mk-proj-fib-init ()
  "Either load the *file-index* buffer from the file cache, or create it afresh."
  (if (and mk-proj-file-list-cache
           (file-readable-p mk-proj-file-list-cache))
       (let () 
        (load-project-index))
    (project-index)))

(defun mk-proj-fib-clear ()
  "Clear the contents of the fib buffer"
  (setq mk-proj-file-list-map nil)
  )

(defun mk-proj-fib-cb (process event)
  "Handle failure to complete fib building"
  (setq mk-proj-index-running nil)
  (cond
   ((string= event "finished\n")
    (with-current-buffer (get-buffer mk-proj-fib-name)
      (setq buffer-read-only t)
      (when mk-proj-file-list-cache
        (write-file mk-proj-file-list-cache)
        (load-project-index)
	(mk-proj-maybe-kill-buffer mk-proj-fib-name)
        ))
    (message "Refreshing %s buffer...done,prepare taging" mk-proj-fib-name)
    (project-tags)
    )
   (t
    (mk-proj-fib-clear)
    (message "Failed to generate the %s buffer!%s" mk-proj-fib-name event))))

(defun project-index ()
  "Regenerate the *file-index* buffer that is used for project-find-files"
  (interactive)
  (mk-proj-assert-proj)
  (if mk-proj-index-running
    (error "file-index is processing!"))
  (when mk-proj-file-list-cache
    (let* ((default-directory (file-name-as-directory mk-proj-basedir))
           (start-dir (if mk-proj-subdir (mapconcat (function (lambda (x) (format "'%s'" x))) mk-proj-subdir " ") "."))
           (find-cmd (concat mk-proj-find-cmd " " start-dir " -type f "
                            (mk-proj-find-cmd-match-args mk-proj-src-patterns)))
           (proc-name "index-process"))
      (when (mk-proj-get-vcs-path)
        (setq find-cmd (concat find-cmd " -not -path " (mk-proj-get-vcs-path))))
      (setq find-cmd (or (mk-proj-find-cmd-val 'index) find-cmd))
      (with-current-buffer (get-buffer-create mk-proj-fib-name)
        (buffer-disable-undo) ;; this is a large change we don't need to undo
        (setq buffer-read-only nil))
      (message "project-index cmd: \"%s\"" find-cmd)
      (message "Refreshing %s buffer..." mk-proj-fib-name)
      (start-process-shell-command proc-name mk-proj-fib-name (concat find-cmd ""))
	  (setq mk-proj-index-running t)
      (set-process-sentinel (get-process proc-name) 'mk-proj-fib-cb))))

(defun mk-proj-fib-matches (regex)
  "Return list of files in *file-index* matching regex.

If regex is nil, return all files. Returned file paths are
relative to the project's basedir."
  (let (files '())
        (maphash (lambda (file v)(if regex
                    (when (string-match regex (file-name-nondirectory file)) (add-to-list 'files file))
                  (add-to-list 'files file))) mk-proj-file-list-map)
       (sort files #'string-lessp)))

(defun mk-proj-normalize-drive-letter (file)
  "Convert drive letters to lowercase to be compatible with
file-relative-name, file-name-as-directory"
  (if (or (null file) (< (length file) 2))
      file
    (let ((c1 (aref file 0))
          (c2 (aref file 1)))
      (if (and (= (aref ":" 0) c2)
               (and (>= c1 (aref "A" 0)) (<= c1 (aref "Z" 0))))
          (concat (char-to-string (+ c1 32)) (substring file 1))
        file))))

(defun* project-find-files (regex)
  "Find file in the current project matching the given regex.

The files listed in buffer *file-index* are scanned for regex
matches. If only one match is found, the file is opened
automatically. If more than one match is found, prompt for
completion. See also: `project-index', `project-find-file-ido'."
  (interactive "sFind file in project matching: ")
  (mk-proj-assert-proj)
  (unless mk-proj-file-list-map
    (message "Please use project-index to create the index before running project-find-files")
    (return-from "project-find-files" nil))
    (let* (
	   (pre (replace-regexp-in-string "\\." "\\\\." regex))
	   (regex2 (replace-regexp-in-string "\*" ".*" pre))
	   (matches (mk-proj-fib-matches regex2))
           (match-cnt (length matches)))
      (
       cond
       ((= 0 match-cnt)
        (message "No matches for \"%s\" in this project" regex2))
       ((= 1 match-cnt )
        (find-file (concat mk-proj-basedir (car matches))))
       (t
        (let ((file (if (mk-proj-use-ido)
                        (ido-completing-read "Multiple matches, pick one (ido): " matches)
                      (completing-read "Multiple matches, pick one: " matches))))
          (when file
            (find-file (concat (file-name-as-directory mk-proj-basedir) file))))))))

(defun etags-tags-apropos_ (regex) ; Doc string?
  ;(interactive)
  (goto-char (point-min))
  (let ((count 0))
    (while (re-search-forward regex nil t)
      (beginning-of-line)
      (setq count (+ count 1))
      (terpri)
      (forward-line 1)
      )
    count
    )
  )
(defun project-find-tag (input)
  (interactive "p")
  (let* (
         (count 0)
         (wap (word-at-point))
         (regexp (if (eq 4 input) (read-string (concat "Find tag for: (default \"" wap "\"): ") nil nil wap) (if wap wap (read-string (concat "Find tag for: (default \"" wap "\"): ") nil nil wap)))
        ))
    (save-excursion
      (let ((first-time t))
        (while (visit-tags-table-buffer (not first-time))
               (setq first-time nil)
               (setq count (etags-tags-apropos_ regexp))
               )))
    ;(message "final count %d" count)
(if (= count 0)
  (error "No tag contains the keyword:%s" regexp)
  (if (= count 1)
    (let* ((buf (find-tag-noselect regexp nil t))
           (pos (with-current-buffer buf (point))))
      (condition-case nil
                      (switch-to-buffer buf)
                      (error (pop-to-buffer buf)))
      (goto-char pos))
        (let ()
         (ring-insert find-tag-marker-ring (point-marker))
        (tags-apropos regexp)
)
    )
  )
)
  )

(defun project-find-tag-exact (input)
  (interactive "p")
  (let* (
         (count 0)
         (wap (word-at-point))
         (regexp_ (if (eq 4 input) (read-string (concat "Find tag for: (default \"" wap "\"): ") nil nil wap) (if wap wap (read-string (concat "Find tag for: (default \"" wap "\"): ") nil nil wap))))
		 (regexp (concat "\\<" regexp_ "\\>"))
		 )
    (save-excursion
      (let ((first-time t))
        (while (visit-tags-table-buffer (not first-time))
               (setq first-time nil)
               (setq count (etags-tags-apropos_ regexp))
               )))
    ;(message "final count %d" count)
(if (= count 0)
  (error "No tag contains the keyword:%s" regexp)
  (if (= count 1)
    (let* ((buf (find-tag-noselect regexp nil t))
           (pos (with-current-buffer buf (point))))
      (condition-case nil
                      (switch-to-buffer buf)
                      (error (pop-to-buffer buf)))
      (goto-char pos))
        (let ()
         (ring-insert find-tag-marker-ring (point-marker))
        (tags-apropos regexp)
)
    )
  )
)
  )

(defun project-multi-occur (regex)
  "Search all open project files for 'regex' using `multi-occur'"
  (interactive "sRegex: " (word-at-point))
  (mk-proj-assert-proj)
  (multi-occur (mk-proj-filter (lambda (b) (if (and (buffer-file-name b) (not (string-equal (buffer-name b) mk-proj-fib-name)) (not (string-equal (buffer-name b) (file-name-nondirectory mk-proj-tags-file)))) (message "show %s " buffer-file-name b) nil))
                               (mk-proj-buffers))
               regex))

;; ---------------------------------------------------------------------
;; Menus
;; ---------------------------------------------------------------------

(defun mk-proj-menu-item (key label fn &optional always-enabled-p)
  "Define a mk-project menu item that may not be enabled if a
  project is not loaded."
  (let ((whole-key `[menu-bar mkproject ,key]))
    (define-key global-map whole-key
                `(menu-item ,label ,fn :enable ,(if always-enabled-p 't 'mk-proj-name)))))

(defun mk-proj-menu-item-separator (key)
  "Define a separator line in the mk-project menu."
  (define-key global-map `[menu-bar mkproject ,key] '(menu-item "--")))

(defun project-menu ()
  "Define a menu for mk-project operations."
  (interactive)
  ;; define a menu in the top-level menu
  (define-key-after
    global-map
    [menu-bar mkproject]
    (cons "mk-project" (make-sparse-keymap))
    'tools)

  ;; define the menu items in reverse order
  (mk-proj-menu-item 'create   "Create Project"     'project-create t)
  (mk-proj-menu-item 'delete   "Delete Project"     'project-delete t)
  (mk-proj-menu-item 'edit   "Edit Project"     'project-edit t)
  (mk-proj-menu-item-separator 's0)
  (mk-proj-menu-item 'tags   "Build TAGS"     'project-tags)
  (mk-proj-menu-item 'index  "Build Index"    'project-index)
  (mk-proj-menu-item-separator 's2)
  (mk-proj-menu-item 'dired  "Browse (dired)" 'project-dired)
  (mk-proj-menu-item 'comp   "Compile   "     'project-compile)
  (mk-proj-menu-item 'occur  "Multi-occur"    'project-multi-occur)
  (mk-proj-menu-item 'ack    "Ack"            'project-ack)
  (mk-proj-menu-item 'grep   "Grep"           'project-grep)
  (mk-proj-menu-item-separator 's1)
  (mk-proj-menu-item 'status "Status"         'project-status)
  (mk-proj-menu-item 'unload "Unload Project" 'project-unload)
  (mk-proj-menu-item 'load   "Load Project"   'project-load t))

(defun project-menu-remove ()
  "Remove the mk-project menu from the menu bar"
  (interactive)
  (global-unset-key [menu-bar mkproject]))

(when mk-proj-menu-on 
  (project-menu))

(provide 'mk-project)

;;; mk-project.el ends here

