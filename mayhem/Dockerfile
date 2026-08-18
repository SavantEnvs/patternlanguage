# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) -- builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). PatternLanguage's full dependency closure (fmt, nlohmann_json,
# CLI11, libwolv, throwing_ptr) is vendored under external/ (git submodules + one plain
# vendored tree -- see mayhem/build.sh header), and the base already ships cmake/ninja/git --
# so no extra apt packages are needed here.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); an empty value breaks clang, so it
# is never baked as ENV -- build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declared WITHOUT a default so an unset arg lets the base ENV flow through to build.sh,
# while an explicit --build-arg (including an EMPTY one, for a no-sanitizer build) overrides it.
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history
# AND the recursively-checked-out submodule content -- see mayhem.yml's
# `submodules: recursive` -- the full dependency closure PatternLanguage needs, see
# mayhem/build.sh) is copied to /mayhem; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# PatternLanguage's own upstream suites (pattern_language_tests via ctest + the plcli
# integration test, built above with NORMAL flags) -- a failing suite fails the image.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
