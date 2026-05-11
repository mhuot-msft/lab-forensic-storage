# Azure Storage Explorer Connection Guide

Connect to the forensic storage account using Azure Storage Explorer with Entra ID authentication over the private endpoint.

## Architecture Overview

```mermaid
flowchart LR
    subgraph Investigator["Investigator Workstation"]
        style Investigator fill:#2B6CB0,color:#fff,stroke:#1A4971
        SE["Azure Storage Explorer"]
    end
    subgraph Security["Authentication"]
        style Security fill:#C05621,color:#fff,stroke:#8B3A16
        ENTRA["Entra ID"]
        RBAC["RBAC Check"]
    end
    subgraph Infra["Private Endpoint Path"]
        style Infra fill:#2F855A,color:#fff,stroke:#1E5C3D
        NET["Approved private path"]
        PE["Private Endpoint"]
    end
    subgraph Storage["ADLS Gen2 (HNS)"]
        style Storage fill:#6B46C1,color:#fff,stroke:#4A3187
        FE["forensic-evidence\n(WORM immutable)"]
        COC["chain-of-custody\n(hash receipts)"]
    end

    SE -->|"1. Sign in"| ENTRA
    ENTRA -->|"2. Token issued"| SE
    SE -->|"3. Connect via"| NET
    NET --> PE
    PE -->|"4. RBAC enforced"| RBAC
    RBAC -->|"5. Access granted"| FE
    RBAC -->|"5. Access granted"| COC
```

## Prerequisites

- [Azure Storage Explorer](https://azure.microsoft.com/products/storage/storage-explorer/) installed (Windows)
- Entra ID account with **Storage Blob Data Contributor** role on the storage account
- Approved private endpoint access to the storage account

## Step 1: Sign In with Entra ID

```mermaid
flowchart TD
    style A fill:#2B6CB0,color:#fff,stroke:#1A4971
    style B fill:#2B6CB0,color:#fff,stroke:#1A4971
    style C fill:#C05621,color:#fff,stroke:#8B3A16
    style D fill:#C05621,color:#fff,stroke:#8B3A16
    style E fill:#2F855A,color:#fff,stroke:#1E5C3D
    style F fill:#6B46C1,color:#fff,stroke:#4A3187

    A["Open Storage Explorer"] --> B["Add an Account\n(person icon)"]
    B --> C["Select 'Subscription'\n→ Azure environment"]
    C --> D["Sign in with\nEntra ID credentials"]
    D --> E["Select subscription\ncontaining forensic account"]
    E --> F["Storage account appears\nunder Blob Containers"]
```

1. Open Azure Storage Explorer
2. Click **Add an account** (person icon in the left toolbar) or go to **Edit > Add an Account**
3. Select **Subscription** and click **Next**
4. Select **Azure** as the Azure environment
5. Click **Sign in** and authenticate with your organizational Entra ID account
6. After sign-in, select the subscription containing the forensic storage account and click **Apply**

> **Note:** Shared key access is disabled on this storage account. You must sign in with Entra ID -- access keys and SAS tokens will not work.

## Step 2: Navigate to the Storage Account

1. In the left panel under **Storage Accounts**, expand the subscription
2. Locate the forensic storage account (e.g., `forensiclab...`)
3. Expand **Blob Containers** to see the two containers:
   - `forensic-evidence` -- WORM-immutable evidence storage
   - `chain-of-custody` -- hash receipts and audit records

### Container and Folder Hierarchy

Because HNS (Hierarchical Namespace) is enabled, Storage Explorer shows real folders (not virtual prefixes). You can create, rename, and set ACLs on folders directly.

```mermaid
flowchart TD
    style SA fill:#6B46C1,color:#fff,stroke:#4A3187
    style FE fill:#6B46C1,color:#fff,stroke:#4A3187
    style COC fill:#6B46C1,color:#fff,stroke:#4A3187
    style CASES fill:#2B6CB0,color:#fff,stroke:#1A4971
    style C1 fill:#2B6CB0,color:#fff,stroke:#1A4971
    style C2 fill:#2B6CB0,color:#fff,stroke:#1A4971
    style DI fill:#2D8BA4,color:#fff,stroke:#1E6B80
    style EM fill:#2D8BA4,color:#fff,stroke:#1E6B80
    style PH fill:#2D8BA4,color:#fff,stroke:#1E6B80
    style HR fill:#C05621,color:#fff,stroke:#8B3A16
    style H1 fill:#C05621,color:#fff,stroke:#8B3A16

    SA["forensiclab... (ADLS Gen2)"]
    SA --> FE["forensic-evidence/"]
    SA --> COC["chain-of-custody/"]

    FE --> CASES["cases/"]
    CASES --> C1["CASE-2024-001/"]
    CASES --> C2["CASE-2024-002/"]
    C1 --> DI["drive-images/"]
    C1 --> EM["email/"]
    C1 --> PH["phone/"]

    COC --> HR["hashes/"]
    HR --> H1["CASE-2024-001/\n*.sha256.json"]
```

## Step 3: Working with Evidence

### What an Investigator Sees in Storage Explorer

```mermaid
flowchart LR
    style TREE fill:#2F855A,color:#fff,stroke:#1E5C3D
    style MAIN fill:#6B46C1,color:#fff,stroke:#4A3187
    style PROPS fill:#C05621,color:#fff,stroke:#8B3A16
    style TOOLBAR fill:#2B6CB0,color:#fff,stroke:#1A4971

    TREE["Left Panel\n─────────────\nSubscription\n └ forensiclab...\n   └ Blob Containers\n     ├ forensic-evidence\n     └ chain-of-custody"]
    MAIN["Center Panel\n──────────────\ncases/\n └ CASE-2024-001/\n   ├ drive-images/\n   ├ email/\n   └ phone/"]
    PROPS["Properties Panel\n────────────────\nHash: sha256=ab12...\nRetention: 365 days\nCreated: 2024-01-15\nModified by: user@org"]
    TOOLBAR["Toolbar\n────────\nUpload │ Download\nNew Folder │ Refresh"]

    TOOLBAR --> MAIN
    TREE --> MAIN
    MAIN --> PROPS
```

### Upload Evidence

- **Drag and drop** files from Windows Explorer into the appropriate case folder
- Or click the **Upload** button and select files/folders
- HNS ensures folders are real filesystem objects -- no empty marker blobs needed

### Create Case Folders

- Right-click > **Create New Folder** to build the case hierarchy:
  - `cases/CASE-2024-001/drive-images/`
  - `cases/CASE-2024-001/email/`
  - `cases/CASE-2024-001/phone/`
- With HNS enabled, folders support POSIX-like ACLs for fine-grained access control

### Download Evidence

- Select a blob and click **Download**, or right-click > **Download**

### Mark for Hashing

- Right-click a blob > **Properties**
- Under **Metadata**, add: `hash-status` = `pending`
- Click **Save**
- Wait 15-30 seconds, then refresh -- hash metadata will appear
- Hash receipts are written to the `chain-of-custody` container automatically

### View Blob Metadata

- Right-click > **Properties** to see hash values, timestamps, and other metadata

## Step 4: Verify Private Endpoint Reachability

```mermaid
flowchart TD
    style START fill:#2B6CB0,color:#fff,stroke:#1A4971
    style DNS fill:#2F855A,color:#fff,stroke:#1E5C3D
    style PRIVATE fill:#2F855A,color:#fff,stroke:#1E5C3D
    style PUBLIC fill:#C05621,color:#fff,stroke:#8B3A16
    style NET fill:#2F855A,color:#fff,stroke:#1E5C3D
    style OK fill:#2F855A,color:#fff,stroke:#1E5C3D

    START["Cannot connect to\nstorage account?"] --> DNS["Run: nslookup\n<account>.blob.core.windows.net"]
    DNS -->|"Resolves to 10.0.0.x"| PRIVATE["DNS is correct\n(private IP)"]
    DNS -->|"Resolves to public IP"| PUBLIC["Fix DNS configuration\nfor your environment"]
    PRIVATE --> NET["Check approved private\naccess path is active"]
    PUBLIC --> NET
    NET --> OK["Connection\nestablished"]
```

If you cannot connect:

1. Verify DNS resolution to the private endpoint:
   ```
   nslookup <storage-account-name>.blob.core.windows.net
   ```
   Should resolve to a private IP (e.g., `10.0.0.x`), not a public IP.

2. Ensure your approved private access path is active.

## Step 5: Multiple Investigators

Each investigator signs in with their own Entra ID account. All investigators with the **Storage Blob Data Contributor** role see both containers:

- `forensic-evidence` -- upload, read, and manage evidence
- `chain-of-custody` -- read hash receipts for integrity verification

The audit trail in Log Analytics differentiates actions by individual Entra ID principal.

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| "Shared key authentication is not permitted" | Storage account has shared key access disabled | Ensure you are signed in with Entra ID, not using an access key |
| "This request is not authorized" | Missing RBAC role | Verify Storage Blob Data Contributor role is assigned at the storage account scope |
| "Unable to connect" | No approved private endpoint path | Ensure your approved private access path is active |
| Cannot upload/delete | Immutability policy active | Uploads to new paths succeed; deletes of retained blobs are blocked by design |
| TLS handshake failure | Network proxy or security agent intercepting traffic | Check for network security agents that may interfere with private endpoint connections |
| Folders appear as blobs | HNS not recognized | Ensure Storage Explorer is updated to the latest version for full ADLS Gen2 support |
