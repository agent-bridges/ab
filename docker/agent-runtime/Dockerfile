FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        openssh-client \
        ca-certificates \
        curl \
        nodejs \
        npm \
        jq \
    && rm -rf /var/lib/apt/lists/*
RUN npm i -g @openai/codex
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN ln -sf /root/.local/bin/claude /usr/local/bin/claude

COPY start-agent-runtime.sh /usr/local/bin/start-agent-runtime
RUN chmod +x /usr/local/bin/start-agent-runtime

ENV PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENTRYPOINT ["/usr/local/bin/start-agent-runtime"]
