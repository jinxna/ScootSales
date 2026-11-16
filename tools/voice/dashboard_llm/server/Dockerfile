# Build context is the folder made by build_bundle.py (code + model + adapter).
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir torch==2.6.0 --index-url https://download.pytorch.org/whl/cpu
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY tools ./tools
COPY platform_service ./platform_service
COPY model ./model
COPY adapter ./adapter
ENV PYTHONPATH=/app PYTHONUNBUFFERED=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
ENV COPILOT_HOST=0.0.0.0
CMD ["python", "-m", "tools.voice.dashboard_llm.server.app"]
