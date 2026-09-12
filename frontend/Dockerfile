ARG NODE_BASE_IMAGE=node:22-alpine
ARG NGINX_BASE_IMAGE=nginx:1.27-alpine

FROM ${NODE_BASE_IMAGE} AS build

ARG NPM_REGISTRY=https://registry.npmmirror.com

WORKDIR /app
RUN npm config set registry "${NPM_REGISTRY}" \
    && npm config set audit false \
    && npm config set fund false

COPY frontend/package.json ./package.json
RUN npm install --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

FROM ${NGINX_BASE_IMAGE}
COPY frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
