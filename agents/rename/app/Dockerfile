# Amazon Linux 2023 ARM64 base for Graviton compatibility with AgentCore Runtime.
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

RUN yum install -y python3.11 python3.11-pip && \
    yum clean all && \
    rm -rf /var/cache/yum

WORKDIR /app

COPY requirements.txt .
RUN pip3.11 install --upgrade pip && \
    pip3.11 install --no-cache-dir -r requirements.txt

COPY src/ ./src/

ENV PYTHONUNBUFFERED=1

CMD ["python3.11", "src/agent.py"]
