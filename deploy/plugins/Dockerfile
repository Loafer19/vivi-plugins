# plugins.viviplayer.app: plugin marketplace + catalog (index.json) built by scripts/build-marketplace.py.
# Dokploy app "vivi-plugins" (project "vivi") builds this file from the root of Loafer19/vivi-plugins
# on every push to master.
FROM python:3.12-alpine AS build
WORKDIR /src
COPY . .
# git: "Recently updated" uses commit times when .git is in the build context (falls back to changelog dates).
RUN pip install --no-cache-dir pillow && apk add --no-cache git && git config --global --add safe.directory /src
RUN python3 scripts/build-marketplace.py /out
FROM nginx:1.27-alpine
COPY deploy/plugins/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /out /usr/share/nginx/html
