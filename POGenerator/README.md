# PO Generator

A simple iOS app for generating purchase order numbers as material requests come in.

## How PO numbers are built

For job number `4521-10234` and customer `Acme Corp`, requesting the 2nd PO for that job:

```
0234   -  2   -  ACME
^last 4   ^Nth PO   ^first 4 letters
 digits    for this   of customer
 of job     job        name
 number
```

Result: **`0234-2-ACME`**

- **Core (4 digits):** the last 4 digits of the job number.
- **Sequence digit:** how many POs have been generated for that job so far (1st, 2nd, 3rd...).
- **Customer letters:** the first 4 letters of the customer name, uppercased.

## Shared, multi-device counting

Since multiple employees can request POs for the same job from different phones,
the sequence count is stored in a shared CloudKit "public database" record per job
(not on-device), and incremented using CloudKit's optimistic-concurrency save
policy with automatic retry (`CloudKitManager.swift`). This prevents two people
generating a PO for the same job at the same moment from getting a duplicate
sequence number. Every generated PO is also written to a shared history list that
all employees can see in the "History" tab.

## One-time setup before you can build & run

1. Open `POGenerator.xcodeproj` in Xcode.
2. Select the `POGenerator` target > **Signing & Capabilities**, and set your own
   Apple Developer **Team**.
3. Change `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.example.POGenerator`) to
   something under your own domain, e.g. `com.yourcompany.POGenerator`.
4. Update the iCloud container identifier to match in
   `POGenerator/POGenerator.entitlements` (`iCloud.<your bundle id>`), and in
   Xcode's iCloud capability panel make sure that same container is checked with
   **CloudKit** enabled.
5. Build and run on a device or simulator signed in to iCloud (Settings > [Your
   Name]) for at least one employee's device — the `JobCounter` and
   `PurchaseOrder` record types are created automatically the first time the app
   saves data, in the CloudKit *Development* environment.
6. Before shipping to the team (TestFlight/App Store), open the
   [CloudKit Dashboard](https://icloud.developer.apple.com/), and use
   **Deploy Schema Changes** to push the `JobCounter` and `PurchaseOrder` record
   types from Development to Production.
7. Every employee needs to be signed in to iCloud on their phone (any Apple ID
   works — they don't need to share one account) since data is stored in the
   app's public CloudKit database, readable/writable by anyone running the app.

## Project layout

- `PONumberFormatter.swift` — pure PO number formatting logic.
- `PurchaseOrder.swift` — the PO data model.
- `CloudKitManager.swift` — shared counter + history storage in CloudKit.
- `POStore.swift` — view model wiring UI to CloudKit.
- `GenerateView.swift` — "New PO" tab: enter job number + customer, generate.
- `HistoryView.swift` — "History" tab: shared list of all generated POs.
