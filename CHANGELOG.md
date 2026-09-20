# Changelog

## [1.3.0](https://github.com/eSlider/tty-tunnel/compare/v1.2.1...v1.3.0) (2026-09-20)


### Features

* **opencode:** run OpenCode v2 in an isolated container with a Termix tab ([a60c2a2](https://github.com/eSlider/tty-tunnel/commit/a60c2a21b557b20e40ac07275db09d5414969480))


### Bug Fixes

* **ci:** silence hadolint DL3006 on the parameterised OpenCode base image ([6a33784](https://github.com/eSlider/tty-tunnel/commit/6a3378424c8569a08467e2b04039719deee9bbbc))


### Documentation

* note that release-please PR checks are skipped by GitHub ([ed64ce8](https://github.com/eSlider/tty-tunnel/commit/ed64ce8c3297b44402a36eea88c99f72fcb81ec6))

## [1.2.1](https://github.com/eSlider/tty-tunnel/compare/v1.2.0...v1.2.1) (2026-09-20)


### Bug Fixes

* **ci:** publish release images after release-please tags ([d8ad1d8](https://github.com/eSlider/tty-tunnel/commit/d8ad1d8d3626e8db2e9bfab16c0ed044635aa93c))

## [1.2.0](https://github.com/eSlider/tty-tunnel/compare/v1.1.0...v1.2.0) (2026-09-20)


### Features

* **cli:** bootstrap the container runtime on a fresh machine ([8efe62b](https://github.com/eSlider/tty-tunnel/commit/8efe62b243de7d1306c5e483637add25e6186634))

## [1.1.0](https://github.com/eSlider/tty-tunnel/compare/v1.0.0...v1.1.0) (2026-09-20)


### Features

* **cli:** one-liner tty-tunnel.sh that starts the stack and prints the access table ([8cdf6be](https://github.com/eSlider/tty-tunnel/commit/8cdf6bebea7229200afc4d7ba673a512d380b84e))


### Bug Fixes

* **cli:** wait for the tunnel to be reachable before printing the checks ([9e5e0c6](https://github.com/eSlider/tty-tunnel/commit/9e5e0c6647474516e29026f3e3025dfcada6c6ed))
