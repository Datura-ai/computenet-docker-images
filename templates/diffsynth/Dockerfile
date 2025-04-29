ARG BASE_IMAGE=daturaai/pytorch:2.6.0-py3.12-cuda12.6.0-devel-ubuntu22.04
FROM ${BASE_IMAGE} as base

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --upgrade pip
RUN pip install -r requirements.txt

# Copy the full project
COPY . .

# Download models or handle them at runtime (optional step)
# RUN python scripts/download_models.py

# Expose Gradio port (change if needed)
EXPOSE 7860
EXPOSE 8501

# Start the app (adjust this if you use a CLI or Jupyter)
CMD ["bash", "start.sh"]
