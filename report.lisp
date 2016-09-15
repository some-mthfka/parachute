#|
 This file is a part of parachute
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.parachute)

(defun resolve-tests (designator)
  (etypecase designator
    (list (mapcan #'resolve-tests designator))
    (package (package-tests designator))
    ((or symbol string)
     (cond ((find-test designator)
            (list (find-test designator)))
           ((find-package designator)
            (package-tests designator))
           (T
            (error "No test or package found for ~s." designator))))))

(defun test (designator &rest args &key (report 'plain) &allow-other-keys)
  (let* ((tests (resolve-tests designator))
         (report (apply #'make-instance report
                        :expression designator
                        (removef args :report)))
         (*context* report))
    (dolist (test tests)
      (eval-in-context report (result-for-testable test report)))
    (summarize report)))

(defclass report (parent-result)
  ())

(defmethod print-object ((report report) stream)
  (print-unreadable-object (report stream :type T)
    (format stream "~a results"
            (length (children report)))))

(defmethod tests-with-status (status (report report))
  (delete-if-not (lambda (a) (typep a 'test))
                 (mapcan #'expression (results-with-status status report))))

(defmethod summarize ((report report))
  report)

(defclass quiet (report)
  ())

(defmethod eval-in-context :around ((report quiet) (result result))
  (when (eql :unknown (status result))
    (handler-case
        (call-next-method)
      (error (err)
        (declare (ignore err))
        (setf (status result) :failed)))))

(defclass plain (report)
  ())

(defvar *level* 0)

(defmethod eval-in-context :before ((report plain) (result test-result))
  ;; This leads to more readable traces as otherwise the hierarchy is
  ;; printed with parents after children.
  (report-on result report))

(defmethod eval-in-context :around ((report plain) (result result))
  (when (eql :unknown (status result))
    (handler-case
        (call-next-method)
      (error (err)
        (warn "Unhandled error when evaluating ~a: ~a" result err)
        (setf (status result) :failed)))
    (report-on result report)))

(defmethod eval-in-context ((report plain) (result value-result))
  (handler-case
      (call-next-method)
    (error (err)
      (setf (value result) err)
      (setf (status result) :failed))))

(defmethod eval-in-context ((report plain) (result result))
  (let ((*level* (1+ *level*)))
    (call-next-method)))

(defmethod report-on :before ((result result) (report plain))
  (format T "~& ~:[      ~;~:*~6,3f~] ~a~v@{    ~} "
          (duration result)
          (case (status result)
            (:passed  #+asdf-unicode "✔" #-asdf-unicode "o")
            (:failed  #+asdf-unicode "✘" #-asdf-unicode "x")
            (:skipped #+asdf-unicode "ー" #-asdf-unicode "-")
            (T        #+asdf-unicode "？" #-asdf-unicode "?"))
          *level* T))

(defmethod report-on :after (thing (report plain))
  (terpri)
  (force-output))

(defmethod report-on ((result result) (report plain))
  (write-string (print-object result :oneline)))

(defun filter-test-results (results)
  (remove-if (lambda (a) (typep a 'test-result)) results))

(defmethod summarize ((report plain))
  (let ((failures (results-with-status :failed report)))
    (format T "~&~%~
             ;; Summary:~%~
             Passed:  ~4d~%~
             Failed:  ~4d~%~
             Skipped: ~4d~%"
            (length (filter-test-results (results-with-status :passed report)))
            (length (filter-test-results failures))
            (length (filter-test-results (results-with-status :skipped report))))
    (when failures
      (format T "~&~%;; Failures:~%")
      (dolist (failure failures)
        (when (typep failure 'test-result)
          (let ((failures (results-with-status :failed failure)))
            (format T "~& ~4d/~4d tests failed in ~a:~%"
                    (length failures) (length (children failure))
                    (print-object failure :oneline))
            (dolist (failure failures)
              (format T "~&~a~%~%" (print-object failure :extensive))))))))
  report)

(defclass interactive (report)
  ())

(defmacro lformat (format &rest args)
  `'(lambda (s) (format s ,format ,@args)))

(defmethod eval-in-context :around ((report interactive) (result result))
  (restart-case
      (call-next-method)
    (retry ()
      :report #.(lformat "Retry testing ~a" (print-object result :oneline))
      (eval-in-context report result))
    (abort ()
      :report #.(lformat "Continue, failing ~a" (print-object result :oneline))
      (setf (status result) :failed))
    (continue ()
      :report #.(lformat "Continue, skipping ~a" (print-object result :oneline))
      (setf (status result) :skipped))
    (pass ()
      :report #.(lformat "Continue, passing ~a" (print-object result :oneline))
      (setf (status result) :passed))))

(defmethod eval-in-context :after ((report interactive) (result result))
  (when (eql :failed (status result))
    (error "Test failed:~%~a" (print-object result :extensive))))
