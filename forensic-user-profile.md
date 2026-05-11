PERSONA_BLOCK: Digital Forensics Investigator (Primary Demo User)

Who they are
- Digital forensics investigator using a small, tightly controlled lab style setup today
- Works mostly at the OS level with a file share or mounted path workflow for day to day investigation tasks 
- Uses established forensic tooling including EnCase and Cellebrite
- Licensing can involve physical USB dongles plugged into workstations today 
- Limited cloud exposure and prefers a familiar experience that looks like what they already use 

What they are trying to do
- Acquire forensic images and preserve an authoritative copy long term 
- Do investigative work on a copy, including keyword search type workflows at the OS level 
- Occasionally retrieve older data if needed for legal or other requests, but that is rare 

What they care about most
- Chain of custody and being able to testify the stored data is the same data that was acquired 
- Immutability to prevent tampering and also protect against deletion or destructive access 
- Auditability of access, least privilege, and alerting if unexpected access occurs 
- Data loss is unacceptable, but recovery time can be slow, days or even weeks can be acceptable 

Access patterns to support in the demo
- Provide a familiar explorer like experience and a mount style option
  - Azure Storage Explorer as a GUI access path 
  - BlobFuse mentioned as a mount capable option 
- Assume they want both options available, to ease transition and preserve the existing feel 

Storage and lifecycle assumptions to model
- Current dataset on the order of 100 TB, with roughly half in a more active zone 
- Investigators stated a desire to keep data accessible for a long period before going colder, with a number of two years mentioned 