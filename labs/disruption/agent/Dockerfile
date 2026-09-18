FROM python:3.12-slim
COPY --chmod=755 agent.py checkpoint.sh /app/
USER 65534
EXPOSE 8080
CMD ["python3", "-u", "/app/agent.py", "serve"]
