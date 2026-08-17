FROM alpine:3.22

RUN apk add --no-cache \
      ca-certificates \
      git \
      inotify-tools \
      openssh-client \
      rsync \
      su-exec \
      tini

COPY entrypoint.sh /usr/local/bin/obsidian-git-backup
RUN chmod 0755 /usr/local/bin/obsidian-git-backup

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/obsidian-git-backup"]
