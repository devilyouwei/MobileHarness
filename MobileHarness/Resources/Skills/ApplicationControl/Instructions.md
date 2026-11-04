## Application and device control
### Scope and functions
App pages, provider/resources, Bluetooth and all windows (including Writer). Use ui.windows IDs; controls leave tasks running. Page text/images: web-browsing.
Read-only queries are XML Actions on the Query Channel: ModelResources.snapshot reads installed resource groups, transfers and progress; Provider.readSettings reads confirmed cloud-enabled status and selected model; Bluetooth.readStatus reads power, connection and discovered device IDs. All take no arguments. Use the exact current catalog aliases. Query Actions return business data, not just completion acknowledgments.
### Navigation and queries
Use openPage only for requested navigation, not as a substitute for a device operation/query or as recovery from a failed query. Valid destinations come from its catalog. Current State may answer a known connection fact; power/discovery, provider settings and resource inventory require the matching query when absent.
For a query followed by navigation, first obtain the query result; on the next request describe it once and issue openPage. Do not infer a setting from requested changes, history or a previous model name. Provider settings are read-only: no key/URL, switch operation or settings-write function is exposed.
### Bluetooth
1. For scan, emit Bluetooth.control with operation="scan". Its accepted result does not list devices or prove connection. On the NEXT request, use Bluetooth.readStatus for actual discovery/connection facts.
2. Connect only with an exact device ID from real status results. A device name, list index, old ID or example is not an ID. If the requested device is absent, explain/ask; do not issue connect with a guessed ID or scan repeatedly.
3. For connect/disconnect, emit Bluetooth.control with the actual supported operation. After its result, query actual status before confirming connection or finishing a connection Task. Never combine a dependent query with its control in the same response.
4. A simple status/scan needs no new Task solely for one command. A user-requested ongoing connection goal can use a Task, following BasicSkill's control-only entry. This Skill does not authorize robot motion; do not nod/wave as a connection test.
### Model resources
Download needs a real resource ID, source endpoint and cellular choice from trusted results/configuration or explicit user input. If missing, ask; do not invent them. With those values known, emit ModelResources.download rather than claiming downloaded or merely opening a page. All attributes are strings, including "true"/"false".
For cancellation, query inventory if the current transfer ID is unknown, then emit ModelResources.cancel with that exact ID on the following request. Await its feedback. Admission/progress/installed/available are distinct; a download goal is not complete just because a transfer was accepted. Avoid polling loops, automatic retry and unregistered background contracts.
Use actual outcomes; report failures without invented success or replay of completed/uncertain effects. Finish only a current matching Task whose goal is confirmed.
### Examples (separate requests)
Requested Settings navigation:
```xml
<openPage destination="settings"/>
```
Requested App album navigation (opens the page; does not export or delete photos):
```xml
<openPage destination="album"/>
```
Requested scan:
```xml
<Bluetooth.control operation="scan"/>
```
After real scan feedback, read actual device status in the next request:
```xml
<Bluetooth.readStatus/>
```
Only after status returns the requested device's actual ID, use that ID in the connect Action.
Requested provider settings:
```xml
<Provider.readSettings/>
```
Requested resource inventory:
```xml
<ModelResources.snapshot/>
```
Requested download, only with all values confirmed (placeholders below are not real IDs):
```xml
<ModelResources.download id="RESOURCE_ID" endpoint="SOURCE_ENDPOINT" allowsCellular="false"/>
```
