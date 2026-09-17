FROM python:3.12-slim
COPY agent.py /app/agent.py
USER 65534
EXPOSE 8080
CMD ["python3", "-u", "/app/agent.py", "serve"]
