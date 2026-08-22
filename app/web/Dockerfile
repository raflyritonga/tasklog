FROM --platform=$BUILDPLATFORM node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG VERSION=dev
ENV VERSION=${VERSION}
RUN npm run build

FROM node:24-alpine
WORKDIR /app
COPY --from=build /src/.output ./.output
ENV NODE_ENV=production
ENV NITRO_PORT=3000
EXPOSE 3000
USER node
CMD ["node", ".output/server/index.mjs"]
