DEMO_GOALS_BLOCK: Forensic Storage Demo

ASSUMPTION_BLOCK: Storage System of Record

System of Record
- Azure Blob Storage is the authoritative system of record for all forensic data in this demo
- Blob storage is used specifically because it provides native support for:
  - Immutability and legal hold semantics
  - Long-term retention with auditability
  - Lifecycle tiering including archive for rarely accessed data

Scope and intent
- All authoritative forensic data MUST be written to Blob storage
- Azure Files is NOT the system of record for forensic data
- Any file-share-like or mounted access is a compatibility or convenience layer only

Immutability assumptions
- Immutability is enforced using Azure Blob immutable storage capabilities
- Legal defensibility depends on Blob-level immutability controls, not filesystem permissions
- The demo should assume immutability is required for authoritative copies and cannot be bypassed
- The demo uses container-level immutability; account-level is supported but out of scope

Access assumptions
- Investigators may access Blob data through:
  - Azure Storage Explorer
  - BlobFuse or equivalent mount technology
- These access paths do not change the authoritative nature of Blob as the system of record

Data classification assumptions
- Authoritative copies live in immutable Blob containers
- Working or analysis copies may be separate but are derived from Blob
- No authoritative forensic data is stored outside Blob storage

Non-assumptions
- Do not assume Azure Files provides sufficient immutability or legal hold for forensic purposes
- Do not assume SMB semantics are required for the authoritative data store
- Do not model Azure Files as a long-term archive

Primary goals of the demo environment
- Demonstrate that Azure storage can meet forensic chain of custody requirements without changing investigator tooling
- Show how immutability and retention controls work in practice, not just conceptually
- Validate that access is least privilege, auditable, and defensible for legal review
- Preserve investigator confidence by avoiding cloud-only or unfamiliar workflows

Functional goals to implement
- Create a storage account suitable for forensic data retention
- Enable container-level immutable storage capabilities for authoritative containers
- Support a clear separation between:
  - An authoritative immutable copy
  - A working copy used for investigation
- Provide visible audit signals showing who accessed data and when
- Model lifecycle tiering from active storage to cold and archive tiers

Experience goals
- Make the environment understandable without cloud expertise
- Ensure the demo can be walked through visually step by step
- Ensure storage appears accessible via:
  - Azure Storage Explorer
  - As a mount via BlobFuse or equivalent tooling
- Avoid requiring users to understand Azure internals during the demo

Security goals
- Disable public access to all storage by default
- Use private endpoint patterns in the demo
- Enable monitoring hooks suitable for Defender for Storage scenarios
- Ensure access events are exportable to a SIEM pipeline stub
- Emphasize prevention of deletion and tampering over performance

Cost and scale modeling goals
- Simulate a realistic forensic archive size using small sample data
- Reflect real-world assumptions such as:
  - Large total data volume
  - Rare access to older cases
- Show how lifecycle rules reduce cost without impacting defensibility
- Move working-copy data to cool or archive tiers after initial investigation
- Avoid detailed cost optimization in the demo itself

What the demo should explicitly avoid
- Do not redesign forensic acquisition workflows, the acquisition will likely use current methodology and the data will be sent into the solution
- Do not assume investigators acquire evidence directly in the cloud
- Do not introduce experimental or preview-only features as core dependencies
- Do not require users to interact directly with Azure Portal during investigation workflows but for demo of whole solution some portal access may be needed.

Definition of success
- Investigator can say “this behaves like what we already do, but safer”
- Legal can say immutability and retention are defensible
- Security can point to clear audit and alerting signals
- IT can see a supportable, repeatable pattern