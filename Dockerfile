FROM nginx:1.27-alpine
ARG APP_ENV=local
ARG VCS_REF=unknown
ARG VCS_URL=local
LABEL org.opencontainers.image.title="ECR Deployment Capstone" \
      org.opencontainers.image.source="$VCS_URL" \
      org.opencontainers.image.revision="$VCS_REF" \
      com.example.environment="$APP_ENV"
COPY index.html /usr/share/nginx/html/index.html
RUN printf '{"environment":"%s","commit":"%s"}\n' "$APP_ENV" "$VCS_REF" > /usr/share/nginx/html/build-info.json
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
