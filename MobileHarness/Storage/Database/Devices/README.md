# Device records

This directory owns devices: native/business identity, name, selection and reconnect preference. DeviceRepository.swift is the SQL-free StorageDevices port; DeviceRow.swift owns schema/indexes and Codable GRDB mapping; SQLiteDeviceRepository.swift implements atomic writes and reads in StorageSQLite. Package.swift assigns these colocated files to their existing targets.

Native discovery/connection belongs to PlatformKit; this repository stores facts and selection, never connects hardware. Selection clears the old selected row and updates the requested row in one transaction. A missing requested device rolls back the clear. Device identity is stable and numbers are not reused.

The shared [SQLite core](../README.md) owns admission, transactions and shutdown. Errors propagate to the caller and StorageFailureReporter. No table helper opens its own pool or manages a worker. See [Database](../README.md) for composition and compiled boundaries.
