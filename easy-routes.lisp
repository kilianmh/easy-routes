(in-package :easy-routes)

(defparameter *routes* (make-hash-table))
(defparameter *routes-mapper* (make-instance 'routes:mapper)
  "This is the cl-routes map of routes.
cl-routes implements special SWANK inspect code and prints routes mappers as a tree.
Just inspect *routes-mapper* from the Lisp listener to see.")

(defparameter *acceptors-routes-and-mappers* (make-hash-table)
  "Routes and route mappers for individual acceptors")

(defvar *route* nil "The current route")

(defclass routes-acceptor (hunchentoot:acceptor)
  ()
  (:documentation "This acceptors handles routes and only routes. If no route is matched then an HTTP NOT FOUND error is returned.
If you want to use Hunchentoot easy-handlers dispatch as a fallback, use EASY-ROUTES-ACCEPTOR"))

(defun acceptor-routes-mapper (acceptor-name)
  (or (getf (gethash acceptor-name *acceptors-routes-and-mappers*)
            :routes-mapper)
      *routes-mapper*))

(defun acceptor-routes (acceptor-name)
  (or (getf (gethash acceptor-name *acceptors-routes-and-mappers*)
            :routes)
      *routes*))

(defun ensure-acceptor-routes-and-mapper (acceptor-name)
  (or (gethash acceptor-name *acceptors-routes-and-mappers*)
      (setf (gethash acceptor-name *acceptors-routes-and-mappers*)
            (list :routes (make-hash-table) :routes-mapper (make-instance 'routes:mapper)))))

(defmethod hunchentoot:acceptor-dispatch-request
    ((acceptor routes-acceptor) request)
  (flet ((not-found-if-null (thing)
           (unless thing
             (setf (hunchentoot:return-code*)
                   hunchentoot:+http-not-found+)
             (hunchentoot:abort-request-handler))))
    (multiple-value-bind (*route* bindings)
        (routes:match (acceptor-routes-mapper (hunchentoot:acceptor-name acceptor))
          (hunchentoot:request-uri request))
      (not-found-if-null *route*)
      (handler-bind ((error #'hunchentoot:maybe-invoke-debugger))
        (let ((result (process-route acceptor *route* bindings)))
          (cond
            ((pathnamep result)
             (hunchentoot:handle-static-file
              result
              (or (hunchentoot:mime-type result)
                  (hunchentoot:content-type hunchentoot:*reply*))))
            (t result)))))))

(defclass easy-routes-acceptor (hunchentoot:easy-acceptor)
  ()
  (:documentation "This acceptor tries to match and handle easy-routes first, but fallbacks to easy-routes dispatcher if there's no matching"))

(defclass easy-routes-ssl-acceptor (easy-routes-acceptor hunchentoot:ssl-acceptor)
  ()
  (:documentation "As for EASY-ROUTES-ACCEPTOR, but works with the hunchentoot EASY-SSL-ACCEPTOR instead."))

(defmethod hunchentoot:acceptor-dispatch-request ((acceptor easy-routes-acceptor) request)
  (multiple-value-bind (*route* bindings)
      (routes:match (acceptor-routes-mapper (hunchentoot:acceptor-name acceptor))
        (hunchentoot:request-uri request))
    (if (not *route*)
        ;; Fallback to dispatch via easy-handlers
        (call-next-method)
        ;; else, a route was matched
        (handler-bind ((error #'hunchentoot:maybe-invoke-debugger))
          (let ((result (process-route acceptor *route* bindings)))
            (cond
              ((pathnamep result)
               (hunchentoot:handle-static-file
                result
                (or (hunchentoot:mime-type result)
                    (hunchentoot:content-type hunchentoot:*reply*))))
              (t result)))))))

(defclass route (routes:route)
  ((symbol :initarg :symbol
           :reader route-symbol)
   (variables :initarg :variables
              :reader variables)
   (required-method :initarg :required-method
                    :initform nil
                    :reader required-method)
   (decorators :initarg :decorators
               :initform nil
               :reader route-decorators
               :type list)))

(defmethod print-object ((route route) stream)
  (print-unreadable-object (route stream :type t :identity t)
    (with-slots (symbol required-method routes::template) route
      (format stream "~A: ~A ~S" symbol required-method routes::template))))

(defmethod routes:route-check-conditions ((route route) bindings)
  (with-slots (required-method) route
    (and required-method
         (eql (hunchentoot:request-method*) required-method)
         t)))

(defmethod routes:route-name ((route route))
  (string-downcase (write-to-string (slot-value route 'symbol))))

(defun call-decorator (decorator next)
  (if (listp decorator)
      (apply (first decorator) (append (rest decorator) (list next)))
      (funcall decorator next)))

(defun call-with-decorators (decorators function)
  (if (null decorators)
      (funcall function)
      (call-decorator (first decorators)
                      (lambda ()
                        (call-with-decorators (rest decorators) function)))))

(defgeneric process-route (acceptor route bindings))

(defmethod process-route ((acceptor hunchentoot:acceptor) (route route) bindings)
  (call-with-decorators
   (route-decorators route)
   (lambda ()
     (apply (route-symbol route)
            (loop for item in (slot-value route 'variables)
                  collect (cdr (assoc item bindings
                                      :test #'string=)))))))

(defun connect-routes (acceptor-name)
  (let* ((routes-and-mapper (if acceptor-name
                                (ensure-acceptor-routes-and-mapper acceptor-name)
                                (list :routes *routes* :routes-mapper *routes-mapper*)))
         (routes (getf routes-and-mapper :routes))
         (routes-mapper (getf routes-and-mapper :routes-mapper)))
    (routes:reset-mapper routes-mapper)
    (loop for route being the hash-values of routes
          do
             (routes:connect routes-mapper route))))

(defmethod make-load-form ((var routes:variable-template) &optional env)
  (declare (ignorable env))
  `(routes::make-variable-template ',(routes::template-data var)))

(defmacro defroute (name template-and-options params &body body)
  "Route definition syntax"
  (let* ((template (if (listp template-and-options)
                       (first template-and-options)
                       template-and-options))
         (variables (routes:template-variables
                     (routes:parse-template template)))
         (arglist (mapcar (alexandria:compose #'intern #'symbol-name)
                          variables))
         (method (or (and (listp template-and-options)
                          (getf (rest template-and-options) :method))
                     :get))
         (acceptor-name (getf (rest template-and-options) :acceptor-name))
         (decorators (and (listp template-and-options)
                          (getf (rest template-and-options) :decorators)))
         (declarations (loop
                         for x = (first body)
                         while (and (listp x) (equalp (first x) 'declare))
                         do (pop body)
                         collect x)))
    (assoc-bind ((params nil)
                 (get-params :&get)
                 (post-params :&post)
                 (path-params :&path))
        (lambda-list-split '(:&get :&post :&path) params)
      `(let ((%route (make-instance 'route
                                    :symbol ',name
                                    :template ',(routes:parse-template template)
                                    :variables ',variables
                                    :required-method ',method
                                    :decorators ',decorators)))
         ,(if acceptor-name
              `(let ((%routes-and-mapper (ensure-acceptor-routes-and-mapper ',acceptor-name)))
                 (setf (gethash ',name (getf %routes-and-mapper :routes)) %route))
              `(setf (gethash ',name *routes*) %route))
         (connect-routes ',acceptor-name)
         (defun ,name ,arglist
           ,@declarations
           (let (,@(loop for param in params
                         collect
                         (hunchentoot::make-defun-parameter param ''string :both))
                 ,@(loop for param in get-params
                         collect
                         (hunchentoot::make-defun-parameter param ''string :get))
                 ,@(loop for param in post-params
                         collect
                         (hunchentoot::make-defun-parameter param ''string :post))
                 ,@(loop for param in path-params
                         collect
                         (destructuring-bind (parameter-name parameter-type) param
                           `(,parameter-name (hunchentoot::convert-parameter ,parameter-name ,parameter-type)))))
             ,@body))))))

(defun find-route (name &key acceptor-name)
  "Find a route by name (symbol)"
  (let ((routes (if acceptor-name (acceptor-routes acceptor-name)
                    *routes*)))
    (gethash name routes)))

;; Code here is copied almost exactly from restas library by Moskvitin Andrey

;; Url generation from route name

(defun route-symbol-template (route-symbol)
  (routes:parse-template (find-route route-symbol)))

(defmethod make-route-url ((tmpl list) args)
  (let* ((uri (make-instance 'puri:uri))
         (bindings (loop for rest on args by #'cddr
                         for key = (first rest)
                         for value = (second rest)
                         collect
                         (cons key
                               (if (or (stringp value) (consp value))
                                   value
                                   (write-to-string value)))))
         (query-part (set-difference bindings
                                     (routes:template-variables tmpl)
                                     :test (alexandria:named-lambda
                                               known-variable-p (pair var)
                                             (eql (car pair) var)))))
    (setf (puri:uri-parsed-path uri)
          (cons :absolute
                (routes::apply-bindings tmpl bindings)))
    (when query-part
      (setf (puri:uri-query uri)
            (format nil
                    "~{~(~A~)=~A~^&~}"
                    (alexandria:flatten query-part))))
    uri))

(defmethod make-route-url ((route symbol) args)
  (make-route-url (or (find-route route :acceptor-name (getf args :acceptor-name))
                      (error "Unknown route: ~A" route)) args))

(defmethod make-route-url ((route route) args)
  (make-route-url (routes:route-template route) args))

(defun genurl (route-symbol &rest args &key &allow-other-keys)
  "Generate a relative url from a route name and arguments"
  (puri:render-uri (make-route-url route-symbol args) nil))

(defun genurl* (route-symbol &rest args &key &allow-other-keys)
  "Generate an absolute url from a route name and arguments"
  (let ((url (make-route-url route-symbol args)))
    (setf (puri:uri-scheme url) :http
          (puri:uri-host url)
          (if (boundp 'hunchentoot:*request*)
              (hunchentoot:host)
              "localhost"))
    (puri:render-uri url nil)))

;; Redirect

(defun apply-format-aux (format args)
  (if (symbolp format)
      (apply #'genurl format args)
      (if args
          (apply #'format nil (cons format args))
          format)))

(defun redirect (route-symbol &rest args)
  "Redirect to a route url. Pass the route name and the parameters."
  (hunchentoot:redirect
   (hunchentoot:url-decode
    (apply-format-aux route-symbol
                      (mapcar #'(lambda (s)
                                  (if (stringp s)
                                      (hunchentoot:url-encode s)
                                      s))
                              args)))))

;; Copied code ends here

;; Decorators

(defun @html (next)
  "HTML decoration. Sets reply content type to text/html"
  (setf (hunchentoot:content-type*) "text/html")
  (funcall next))

(defun @json (next)
  "JSON decoration. Sets reply content type to application/json"
  (setf (hunchentoot:content-type*) "application/json")
  (funcall next))

(defun @check (predicate http-error next)
  (if (funcall predicate)
      (funcall next)
      (http-error http-error)))

(defun @check-permission (predicate next)
  (if (funcall predicate)
      (funcall next)
      (permission-denied-error)))

;; HTTP Errors

(defun http-error (http-error)
  (setf (hunchentoot:return-code*) http-error)
  (hunchentoot:abort-request-handler))

(defun not-found-error ()
  (http-error hunchentoot:+http-not-found+))

(defun permission-denied-error ()
  (http-error hunchentoot:+http-forbidden+))

(defun or-http-error (value http-error)
  (or value
      (http-error http-error)))

(defun or-not-found (value)
  (or-http-error value hunchentoot:+http-not-found+))
