import azure.functions as func
import json
import logging
import hashlib
from datetime import datetime, timezone
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

app = func.FunctionApp()

HASH_INDEX_CONTAINER = "chain-of-custody"


@app.function_name(name="HashEvidence")
@app.event_grid_trigger(arg_name="event")
def hash_evidence(event: func.EventGridEvent):
    """Compute SHA-256 for new evidence blobs and write a hash receipt to chain-of-custody."""
    logging.info("Event received: %s, type: %s", event.id, event.event_type)

    data = event.get_json()
    blob_url = data.get("url", "")

    # Parse storage account name and path from the URL
    # URL format: https://<account>.blob.core.windows.net/<container>/<blob>
    parts = blob_url.split(".blob.core.windows.net/", 1)
    if len(parts) != 2:
        logging.warning("Could not parse blob URL: %s", blob_url)
        return

    account_name = parts[0].rsplit("/", 1)[-1]
    path = parts[1]
    container_name = path.split("/", 1)[0]
    blob_name = path.split("/", 1)[1] if "/" in path else ""

    if container_name != "forensic-evidence":
        logging.info("Ignoring event for container: %s", container_name)
        return

    if not blob_name:
        logging.warning("No blob name in URL: %s", blob_url)
        return

    # Connect using managed identity
    credential = DefaultAzureCredential()
    account_url = f"https://{account_name}.blob.core.windows.net"
    blob_service = BlobServiceClient(account_url=account_url, credential=credential)
    blob_client = blob_service.get_blob_client(container_name, blob_name)

    # Check if a hash receipt already exists in chain-of-custody
    receipt_name = f"{blob_name}.sha256.json"
    receipt_client = blob_service.get_blob_client(HASH_INDEX_CONTAINER, receipt_name)
    try:
        receipt_client.get_blob_properties()
        logging.info("Hash receipt already exists for %s. Skipping.", blob_name)
        return
    except Exception:
        pass  # Receipt doesn't exist yet — proceed

    properties = blob_client.get_blob_properties()
    logging.info("Computing SHA-256 for blob: %s (%d bytes)", blob_name, properties.size)

    try:
        sha256 = hashlib.sha256()
        stream = blob_client.download_blob()
        for chunk in stream.chunks():
            sha256.update(chunk)

        hash_hex = sha256.hexdigest()
        now = datetime.now(timezone.utc).isoformat()

        # Write hash receipt as an immutable JSON blob in chain-of-custody
        receipt = {
            "evidenceBlob": blob_name,
            "evidenceContainer": container_name,
            "storageAccount": account_name,
            "hashAlgorithm": "SHA-256",
            "hashValue": hash_hex,
            "evidenceSizeBytes": properties.size,
            "hashedAt": now,
            "hashedBy": "azure-function/HashEvidence",
            "eventId": event.id,
        }

        receipt_client.upload_blob(
            json.dumps(receipt, indent=2),
            overwrite=False,
            content_settings=ContentSettings(content_type="application/json"),
        )

        logging.info("Hash receipt written for %s: %s", blob_name, hash_hex)

    except Exception as e:
        logging.error("Hash failed for %s: %s", blob_name, str(e))
