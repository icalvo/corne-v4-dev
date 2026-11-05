# Corne v4.1 Vial build environment
# Mount the vial-qmk submodule at /workspace/vial-qmk (see docker-compose.yml).
FROM qmkfm/qmk_cli:latest

ENV PATH="/opt/uv/tools/qmk/bin:${PATH}"

WORKDIR /workspace

COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["compile"]
