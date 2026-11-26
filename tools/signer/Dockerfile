FROM docker.io/library/python:3.13-slim
RUN pip install --no-cache-dir 'oci==2.193.0' && useradd -r -u 10001 signer
COPY signer.py /app/signer.py
USER signer
EXPOSE 8000
CMD ["python", "-u", "/app/signer.py"]
