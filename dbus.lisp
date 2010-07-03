;;;; +----------------------------------------------------------------+
;;;; | DBUS                                               DEATH, 2010 |
;;;; +----------------------------------------------------------------+

(in-package #:dbus)


;;;; Utilities

(define-condition dbus-error (error)
  ()
  (:documentation "The supertype errors related to the DBUS system."))

(defun make-octet-vector (size &rest array-options)
  "Return a fresh vector whose element type is (unsigned-byte 8)."
  (apply #'make-array size :element-type '(unsigned-byte 8) array-options))

(define-condition inexistent-entry (dbus-error)
  ((designator :initarg :designator :reader inexistent-entry-designator))
  (:report (lambda (condition stream)
             (format stream "An inexistent entry was sought using ~S as designator."
                     (inexistent-entry-designator condition)))))

(defun inexistent-entry (designator if-does-not-exist)
  "Called when an inexistent entry was sought using DESIGNATOR, and
acts according to the value of IF-DOES-NOT-EXIST:

  :ERROR - signal an INEXISTENT-ENTRY error with a USE-VALUE restart.

  NIL - return NIL."
  (ecase if-does-not-exist
    (:error
     (restart-case (error 'inexistent-entry :designator designator)
       (use-value (new-value)
         :report "Use a value as entry."
         :interactive prompt-for-value
         new-value)))
    ((nil) nil)))

(defun prompt-for-value ()
  "Interactively prompt for a value.  An expression is read and
evaluated, and its value is returned."
  (format t "Enter an expression to yield a value: ")
  (multiple-value-list (eval (read))))

(define-condition entry-replacement-attempt (dbus-error)
  ((old :initarg :old :reader entry-replacement-attempt-old)
   (new :initarg :new :reader entry-replacement-attempt-new))
  (:report (lambda (condition stream)
             (format stream "Attempted to replace ~S by ~S."
                     (entry-replacement-attempt-old condition)
                     (entry-replacement-attempt-new condition)))))

(defun replace-entry-p (old new if-exists)
  "Return true if the new entry should replace the old one.

IF-EXISTS determines how to find out:

  :ERROR - signal an ENTRY-ALREADY-EXISTS error with a CONTINUE
           restart to replace the entry, and an ABORT restart to not
           replace it.

  :WARN - replace the entry after signaling a warning.

  :DONT-REPLACE - don't replace entry.

  :REPLACE - replace entry."
  (flet ((replace-it () (return-from replace-entry-p t))
         (dont-replace-it () (return-from replace-entry-p nil)))
    (ecase if-exists
      (:error
       (restart-case (error 'entry-replacement-attempt :old old :new new)
         (continue ()
           :report "Replace old entry."
           (replace-it))
         (abort ()
           :report "Don't replace old entry."
           (dont-replace-it))))
      (:warn
       (warn "Replacing existing entry ~S with ~S." old new)
       (replace-it))
      (:dont-replace
       (dont-replace-it))
      (:replace
       (replace-it)))))


;;;; Server addresses

(defclass server-address ()
  ()
  (:documentation "Represents a DBUS server address, consisting of a
transport name and zero or more properties."))

(defgeneric server-address-transport-name (server-address)
  (:documentation "Return the canonical transport name for the server
address."))

(defgeneric server-address-property (name server-address &key if-does-not-exist)
  (:documentation "Return the value of the server address's property
with the supplied name."))

(defclass standard-server-address (server-address)
  ((transport-name :initarg :transport-name :reader server-address-transport-name)
   (properties :initarg :properties :reader server-address-properties))
  (:documentation "Represents a standard server address with a table
of properties."))

(defmethod server-address-property (name (server-address standard-server-address)
                                    &key (if-does-not-exist :error))
  (or (gethash name (server-address-properties server-address))
      (inexistent-entry name if-does-not-exist)))

(defclass generic-server-address (standard-server-address)
  ()
  (:documentation "Represents a server address whose transport is not
supported by the DBUS system."))

(defvar *server-address-classes*
  (make-hash-table :test 'equal)
  "Map transport names to server address classes or class names.")

(defun find-server-address-class (name &key (if-does-not-exist :error))
  "Return the server address class (or class name) corresponding to
NAME."
  (or (gethash name *server-address-classes*)
      (inexistent-entry name if-does-not-exist)))

(defun (setf find-server-address-class) (class name &key (if-exists :warn))
  "Associate a server address class (or class name) with NAME."
  (when-let (old (find-server-address-class name :if-does-not-exist nil))
    (when (not (replace-entry-p old class if-exists))
      (return-from find-server-address-class nil)))
  (setf (gethash name *server-address-classes*) class))

(defun parse-server-addresses-from-stream (in)
  "Parse unescaped server addresses text from a character stream and
return a list of server addresses."
  (let ((server-addresses '())
        (token (make-string-output-stream))
        (state :transport)
        (current-server-address '())
        (char nil))
    (labels ((consume ()
               (or (setf char (read-char in nil nil))
                   (finish)))
             (finish ()
               (finish-token)
               (finish-server-address)
               (return-from parse-server-addresses-from-stream
                 (nreverse server-addresses)))
             (finish-token (&optional ignore-empty)
               (let ((string (get-output-stream-string token)))
                 (when (or (plusp (length string))
                           (not ignore-empty))
                   (push string current-server-address))))
             (finish-server-address ()
               (when current-server-address
                 (destructuring-bind (type &rest plist)
                     (nreverse current-server-address)
                   (push (make-instance
                          (or (find-server-address-class type :if-does-not-exist nil)
                              'generic-server-address)
                          :transport-name type
                          :properties (plist-hash-table plist :test 'equal))
                         server-addresses))
                 (setf current-server-address '())))
             (add-to-token ()
               (write-char char token)))
      (loop
       (ecase state
         (:transport
          (case (consume)
            (#\: (finish-token) (setf state :key))
            (t (add-to-token))))
         (:key
          (case (consume)
            (#\; (finish-token t) (finish-server-address) (setf state :transport))
            (#\= (finish-token) (setf state :value))
            (t (add-to-token))))
         (:value
          (case (consume)
            (#\,(finish-token) (setf state :key))
            (#\; (finish-token) (finish-server-address) (setf state :transport))
            (t (add-to-token)))))))))

(defun unescape-server-addresses-string (string)
  "Unescape a server addresses string per the DBUS specification's
escaping rules and return the unescaped string.  The string returned
may be the same as the string supplied if no unescaping is needed."
  (let ((escapes (count #\% string)))
    (if (zerop escapes)
        string
        (let ((octets (make-octet-vector (- (length string) (* 2 escapes))
                                         :fill-pointer 0)))
          (with-input-from-string (in string)
            (loop for char = (read-char in nil nil)
                  while char do
                  (vector-push
                   (if (char= #\% char)
                       (logior (ash (digit-char-p (read-char in) 16) 4)
                               (digit-char-p (read-char in) 16))
                       (char-code char))
                   octets)))
          (babel:octets-to-string octets :encoding :utf-8)))))

(defun parse-server-addresses-string (string)
  "Parse a (possibly escaped) server addresses string into a list of
server addresses."
  (with-input-from-string (in (unescape-server-addresses-string string))
    (parse-server-addresses-from-stream in)))

(defun session-server-addresses ()
  "Return a list of server addresses for the current session."
  (when-let (string (iolib.syscalls:getenv "DBUS_SESSION_BUS_ADDRESS"))
    (parse-server-addresses-string string)))