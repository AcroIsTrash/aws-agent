# Layer 2 — containerize the LangChain calculator agent.
# Build:  docker build -t aws-agent .
# Run:    docker run -it -e OPENAI_API_KEY=sk-... aws-agent

FROM python:3.13-slim
INTENTIONAL_BREAK_FOR_PIPELINE_TEST

# Don't write .pyc files; flush stdout/stderr so logs appear in real time.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Clone the agent at build time — each new image build pulls the latest version.
RUN git clone https://github.com/AcroIsTrash/ai_agent.git .

RUN uv sync --frozen --no-dev

# Run as a non-root user — never run the container as root in production.
RUN useradd --create-home appuser
USER appuser

# OPENAI_API_KEY is passed at runtime (-e OPENAI_API_KEY=...), never baked in.
CMD ["uv", "run", "python", "main.py"]
