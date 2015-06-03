;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2013 Cyril Roelandt <tipecaml@gmail.com>
;;; Copyright © 2014, 2015 Mark H Weaver <mhw@netris.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu packages ocaml)
  #:use-module ((guix licenses) #:hide (zlib))
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix utils)
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages xorg)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages python)
  #:use-module (gnu packages ncurses)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages curl))

(define-public ocaml
  (package
    (name "ocaml")
    (version "4.02.1")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "http://caml.inria.fr/pub/distrib/ocaml-"
                    (version-major+minor version)
                    "/ocaml-" version ".tar.xz"))
              (sha256
               (base32
                "1p7lqvh64xpykh99014mz21q8fs3qyjym2qazhhbq8scwldv1i38"))))
    (build-system gnu-build-system)
    (native-inputs
     `(("perl" ,perl)
       ("pkg-config" ,pkg-config)))
    (inputs
     `(("libx11" ,libx11)
       ("gcc:lib" ,gcc-final "lib") ; for libiberty, needed for objdump support
       ("zlib" ,zlib)))             ; also needed for objdump support
    (arguments
     `(#:modules ((guix build gnu-build-system)
                  (guix build utils)
                  (web server))
       #:phases
       (modify-phases %standard-phases
         (add-after 'unpack 'patch-/bin/sh-references
                    (lambda* (#:key inputs #:allow-other-keys)
                      (let* ((sh (string-append (assoc-ref inputs "bash")
                                                "/bin/sh"))
                             (quoted-sh (string-append "\"" sh "\"")))
                        (with-fluids ((%default-port-encoding #f))
                          (for-each (lambda (file)
                                      (substitute* file
                                        (("\"/bin/sh\"")
                                         (begin
                                           (format (current-error-port) "\
patch-/bin/sh-references: ~a: changing `\"/bin/sh\"' to `~a'~%"
                                                   file quoted-sh)
                                           quoted-sh))))
                                    (find-files "." "\\.ml$"))
                          #t))))
         (replace 'configure
                  (lambda* (#:key outputs #:allow-other-keys)
                    (let* ((out (assoc-ref outputs "out"))
                           (mandir (string-append out "/share/man")))
                      ;; Custom configure script doesn't recognize
                      ;; --prefix=<PREFIX> syntax (with equals sign).
                      (zero? (system* "./configure"
                                      "--prefix" out
                                      "--mandir" mandir)))))
         (replace 'build
                  (lambda _
                    (zero? (system* "make" "-j" (number->string
                                                 (parallel-job-count))
                                    "world.opt"))))
         (delete 'check)
         (add-after 'install 'check
                    (lambda _
                      (with-directory-excursion "testsuite"
                        (zero? (system* "make" "all")))))
         (add-before 'check 'prepare-socket-test
                     (lambda _
                       (format (current-error-port)
                               "Spawning local test web server on port 8080~%")
                       (when (zero? (primitive-fork))
                         (run-server (lambda (request request-body)
                                       (values '((content-type . (text/plain)))
                                               "Hello!"))
                                     'http '(#:port 8080)))
                       (let ((file "testsuite/tests/lib-threads/testsocket.ml"))
                         (format (current-error-port)
                                 "Patching ~a to use localhost port 8080~%"
                                 file)
                         (substitute* file
                           (("caml.inria.fr") "localhost")
                           (("80") "8080")
                           (("HTTP1.0") "HTTP/1.0"))
                         #t))))))
    (home-page "https://ocaml.org/")
    (synopsis "The OCaml programming language")
    (description
     "OCaml is a general purpose industrial-strength programming language with
an emphasis on expressiveness and safety.  Developed for more than 20 years at
Inria it benefits from one of the most advanced type systems and supports
functional, imperative and object-oriented styles of programming.")
    ;; The compiler is distributed under qpl1.0 with a change to choice of
    ;; law: the license is governed by the laws of France.  The library is
    ;; distributed under lgpl2.0.
    (license (list qpl lgpl2.0))))

(define-public opam
  (package
    (name "opam")
    (version "1.1.1")
    (source (origin
              (method url-fetch)
              ;; Use the '-full' version, which includes all the dependencies.
              (uri (string-append
                    "https://github.com/ocaml/opam/releases/download/"
                    version "/opam-full-" version ".tar.gz")
               ;; (string-append "https://github.com/ocaml/opam/archive/"
               ;;                    version ".tar.gz")
               )
              (sha256
               (base32
                "1frzqkx6yn1pnyd9qz3bv3rbwv74bmc1xji8kl41r1dkqzfl3xqv"))))
    (build-system gnu-build-system)
    (arguments
     '(;; Sometimes, 'make -jX' would fail right after ./configure with
       ;; "Fatal error: exception End_of_file".
       #:parallel-build? #f

       ;; For some reason, 'ocp-build' needs $TERM to be set.
       #:make-flags '("TERM=screen")
       #:test-target "tests"

       ;; FIXME: There's an obscure test failure:
       ;;   …/_obuild/opam/opam.asm install P1' failed.
       #:tests? #f

       #:phases (alist-cons-before
                 'build 'pre-build
                 (lambda* (#:key inputs #:allow-other-keys)
                   (let ((bash (assoc-ref inputs "bash")))
                     (substitute* "src/core/opamSystem.ml"
                       (("\"/bin/sh\"")
                        (string-append "\"" bash "/bin/sh\"")))))
                 (alist-cons-before
                  'check 'pre-check
                  (lambda _
                    (setenv "HOME" (getcwd))
                    (and (system "git config --global user.email guix@gnu.org")
                         (system "git config --global user.name Guix")))
                  %standard-phases))))
    (native-inputs
     `(("git" ,git)                               ;for the tests
       ("python" ,python)))                       ;for the tests
    (inputs
     `(("ocaml" ,ocaml)
       ("ncurses" ,ncurses)
       ("curl" ,curl)))
    (home-page "http://opam.ocamlpro.com/")
    (synopsis "Package manager for OCaml")
    (description
     "OPAM is a tool to manage OCaml packages.  It supports multiple
simultaneous compiler installations, flexible package constraints, and a
Git-friendly development workflow.")

    ;; The 'LICENSE' file waives some requirements compared to LGPLv3.
    (license lgpl3)))
