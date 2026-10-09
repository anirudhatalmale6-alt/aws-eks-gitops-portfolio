# syntax=docker/dockerfile:1

#
# Demo workload
# =============
# There is no application code in this image on purpose. This project is about
# infrastructure, so the thing being deployed is deliberately boring: nginx
# serving one page, plus /healthz for probes and /stub_status for metrics.
#
# nginx-unprivileged, not nginx
# -----------------------------
# The official nginx image starts as root to bind port 80, then drops to the
# nginx user for its workers. That means the Deployment cannot set
# runAsNonRoot: true, and a namespace with the "restricted" Pod Security
# Standard rejects the pod outright.
#
# nginxinc/nginx-unprivileged runs entirely as uid 101 and listens on 8080, so
# the pod can run with runAsNonRoot, a read-only root filesystem and every
# Linux capability dropped. That is the difference between a manifest that
# claims to be hardened and one that actually passes admission.
#
# Fully qualified on purpose. "nginxinc/..." is only short for
# "docker.io/nginxinc/..." because Docker Hub happens to be the default
# registry; spelling it out means the build behaves the same under podman,
# BuildKit, or any runner whose registry search list is configured differently.
FROM docker.io/nginxinc/nginx-unprivileged:1.29-alpine

# How the page learns which pod it is running in, with no application code:
#
#   1. Anything in /etc/nginx/templates ending in .template is run through
#      envsubst by the image's own entrypoint before nginx starts.
#   2. NGINX_ENVSUBST_FILTER restricts that substitution to exactly these
#      variable names. Without the filter, envsubst would also eat nginx's own
#      $host, $remote_addr and $uri and the config would not parse.
#   3. The substituted values land in sub_filter rules, which rewrite the
#      placeholders in index.html on the way out.
#
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html            /usr/share/nginx/html/index.html

# Runs after the image's own 20-envsubst-on-templates.sh and refuses to start
# nginx if the template was not actually rendered. Read the script: it exists
# because the image logs that failure and then starts anyway, serving a
# different site than the one you built.
COPY --chmod=755 docker-entrypoint.d/25-assert-config-rendered.sh /docker-entrypoint.d/25-assert-config-rendered.sh

ENV NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d \
    NGINX_ENVSUBST_FILTER="^(POD_NAME|POD_NAMESPACE|NODE_NAME|POD_IP|APP_VERSION|CLUSTER_NAME)$" \
    POD_NAME=local \
    POD_NAMESPACE=local \
    NODE_NAME=local \
    POD_IP=127.0.0.1 \
    APP_VERSION=dev \
    CLUSTER_NAME=local

# Inherited from the base image, declared again anyway.
#
# Two reasons. A reader of this file should not have to go and read the base
# image's Dockerfile to find out whether this runs as root. And a scanner
# cannot see through FROM, so without this line every image scan reports
# "no USER instruction, may run as root" and the finding has to be argued away
# in every review forever.
#
# 101 is the nginx user in the base image. Kubernetes asserts it independently
# with runAsNonRoot and runAsUser in the Deployment, so a base image that
# changed its user would fail admission rather than quietly run as root.
USER 101

EXPOSE 8080

# For a plain `docker run`. Kubernetes ignores HEALTHCHECK and uses the probes
# in the Deployment instead; this is here so the image is also correct outside
# Kubernetes.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/bin/sh", "-c", "wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1"]
