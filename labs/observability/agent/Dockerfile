FROM python:3.12-slim
RUN pip install --no-cache-dir opentelemetry-sdk==1.44.0
COPY agent.py /app/agent.py
USER 65534
EXPOSE 8080
CMD ["python3", "-u", "/app/agent.py"]
