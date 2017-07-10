(in-package :easy-routes)

(defparameter *routes* (make-hash-table))
(defparameter *routes-mapper* (make-instance 'routes:mapper))

(defclass routes-acceptor (hunchentoot:acceptor)
  ()
  (:documentation "This acceptors handles routes and only routes. If no route is matched then an HTTP NOT FOUND error is returned.
If you want to use Hunchentoot easy-handlers dispatch as a fallback, use EASY-ROUTES-ACCEPTOR"))

(defmethod hunchentoot:acceptor-dispatch-request
    ((acceptor routes-acceptor) request)
  (flet ((not-found-if-null (thing)
           (unless thing
             (setf (hunchentoot:return-code*)
                   hunchentoot:+http-not-found+)
             (hunchentoot:abort-request-handler))))
    (multiple-value-bind (route bindings)
        (routes:match *routes-mapper*
          (hunchentoot:request-uri request))
      (not-found-if-null route)
      (handler-bind ((error #'hunchentoot:maybe-invoke-debugger))
        (let ((result (process-route route bindings)))
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

(defmethod hunchentoot:acceptor-dispatch-request
    ((acceptor easy-routes-acceptor) request)
  (multiple-value-bind (route bindings)
      (routes:match *routes-mapper*
        (hunchentoot:request-uri request))
    (if (not route)
        ;; Fallback to dispatch via easy-handlers
        (call-next-method)
        ;; else, a route was matched
        (handler-bind ((error #'hunchentoot:maybe-invoke-debugger))
           (let ((result (process-route route bindings)))
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

(defmethod routes:route-check-conditions ((route route) bindings)
  (with-slots (required-method) route
    (and required-method
         (eql (hunchentoot:request-method*) required-method)
         t)))

(defmethod routes:route-name ((route route))
  (string-downcase (write-to-string (slot-value route 'symbol))))

(defun call-with-decorators (decorators function)
  (if (null decorators)
      (funcall function)
      (funcall (first decorators)
               (lambda ()
                 (call-with-decorators (rest decorators) function)))))

(defmethod process-route ((route route) bindings)
  (call-with-decorators (route-decorators route)
                        (lambda ()
                          (apply (route-symbol route)
                                 (loop for item in (slot-value route 'variables)
                                    collect (cdr (assoc item bindings
                                                        :test #'string=)))))))

(defun connect-routes ()
  (routes:reset-mapper *routes-mapper*)
  (loop for route being the hash-values of *routes*
     do
       (routes:connect *routes-mapper* route)))

(defmacro defroute (name template-and-options params &body body)
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
         (decorators (and (listp template-and-options)
                          (getf (rest template-and-options) :decorators)))
         (route (make-instance 'route
                               :symbol name
                               :template (routes:parse-template template)
                               :variables variables
                               :required-method method
                               :decorators decorators)))
    (setf (gethash name *routes*) route)
    (connect-routes)
    (assoc-bind ((params nil)
                 (get-params :&get)
                 (post-params :&post)
                 (path-params :&path))
        (lambda-list-split '(:&get :&post :&path) params)
      `(defun ,name ,arglist
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
           ,@body)))))

;; Decorators

(defun @html (next)
  (setf (hunchentoot:content-type*) "text/html")
  (funcall next))

(defun @json (next)
  (setf (hunchentoot:content-type*) "application/json")
  (funcall next))
