# A throwaway managed-mode control plane, for stage 70's tests (plan/19 §5, Phase B).
#
# FROM the builder, deliberately, exactly as tests/ad-dc is: it already carries the pinned
# Portage tree, the binhost trust store from getuto, and this project's SNAPSHOT_DATE — so the
# fixture cannot silently drift from the image under test, and it needs no second base image
# in the vendored archive.
#
# WHY pip AND A VENV, when everything else in this repo is emerged. dev-python/fastapi,
# dev-python/uvicorn, dev-python/starlette and dev-python/pydantic are NOT IN THE PINNED TREE
# (checked against the immos-tree volume on 2026-09-08), so there is no emerge that produces
# this service. The options were: write the fixture against http.server instead, or take the
# dependency in a place where it can never reach the product. This is the second.
#
# The isolation is the whole argument, and it is the same one tests/ad-dc/Dockerfile makes about
# samba's USE flags: a venv under /opt is invisible to portage's "/" configuration, so nothing
# here participates in resolving a single package for the target rootfs. Nothing in the pipeline
# depends on this image, and `bash tests/run-tests.sh` and every offline build work with it
# absent — the tests SKIP, exactly as the domain tests do without a DC.
#
# The versions are pinned for the same reason every other input in this repo is: an unpinned
# fixture is a test that changes underneath you and reports it as a product regression. They are
# also the reason this file names a floor rather than a preference: the builder's python is 3.14,
# and pydantic-core only began publishing cp314 wheels at 2.41 — anything older tries to compile
# Rust in a container that has no cargo, which fails after fifteen seconds of downloading.
ARG BUILDER_TAG=immos-builder:latest
FROM ${BUILDER_TAG}

# --break-system-packages is not needed: this is a venv, which is the point. `--no-deps` is
# deliberately NOT used — pinning the transitive set by hand here would be a lock file with no
# tooling behind it, and this reaches nothing that ships.
RUN python3 -m venv /opt/managed-api/venv \
 && /opt/managed-api/venv/bin/pip install --no-cache-dir --quiet \
      'fastapi==0.141.1' \
      'uvicorn==0.52.4' \
      'pydantic==2.13.5' \
 && /opt/managed-api/venv/bin/python -c 'import fastapi, uvicorn; print("fastapi", fastapi.__version__)'

COPY app.py        /opt/managed-api/app.py
COPY keys          /opt/managed-api/keys
COPY entrypoint.sh /usr/local/bin/managed-api
RUN chmod 0755 /usr/local/bin/managed-api

# Documentation only — the tests use a user-defined docker network where every port is reachable.
EXPOSE 8443/tcp

ENTRYPOINT ["/usr/local/bin/managed-api"]
