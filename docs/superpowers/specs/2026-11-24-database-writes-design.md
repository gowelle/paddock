# Paddock — editing records in the Databases window

Date: 2026-11-24
Status: draft, awaiting review
Adds to: `2026-11-21-paddock-core-design.md`

## Intent

The Databases window can read everything and change nothing. The owner
asked for the obvious next step: edit, delete and create individual
records directly in the grid, without opening a terminal or writing SQL.

That step removes the window's defining guarantee, so most of this
design is about what stays impossible and what a write is allowed to
touch. It follows the same principle as the rest of Paddock: the
database is the owner's, and Paddock should be hard to hurt with.

## Goals

- Change one record's fields in place, save it, and see the grid agree.
- Add one record from a blank row at the grid's end.
- Delete one record after a dialog that names it.
- Keep the SQL console read-only, and keep `paddock db` read-only.
- Never write a row that changed since it was read; never touch a
  table Paddock cannot name a single row in.

## Non-goals

- Bulk edit or bulk delete.
- Creating or altering tables, indexes, constraints, or anything else
  schema-shaped.
- Writes from the CLI (`paddock db insert` and friends, a later piece).
- Undo after a delete, CSV import, foreign-key pickers.
- Editing binary data (BLOBs, `bytea`, geometry) as text.
- A writing mode for the SQL console.

## Anti-goals

These make it a failure even if it works:

- A write can reach a row the owner did not point at. Every update and
  delete names one row by its primary key; there is no free-form WHERE.
- A write can overwrite someone else's change without saying so. Every
  save re-checks the row inside the write's own transaction and refuses
  when it moved.
- A slip of a key is a database change. Saves are explicit (⌘⏎ or the
  Save button), deletes ask first, and the console still refuses writes.
- A truncated display value is written back. Editors load the row afresh
  with full values; the 4096-character grid clipping never feeds a
  write.
- SQL is assembled from typed text. Statements are built from column
  names and values that travel as data, bound as parameters; the owner
  never types SQL to write.

## Decisions the owner made

1. The SQL console stays read-only. Writes exist only through the
   structured row editor.
2. Only tables with a primary key are editable. Views and keyless
   tables say why they are read-only.
3. Editing happens in place, in the row, with Save and Cancel at the
   row's end.
4. New records start as a blank row at the grid's end. Untouched fields
   keep the database default; nullable fields get a NULL toggle.
5. Deleting asks in a dialog that names the row's key.
6. The CLI stays read-only for now.

## How a write travels

Writes use the same bundled PHP/PDO bridge as reads, so the window keeps
talking to the database directly and the daemon is not involved.

A new protocol, `DatabaseWriting`, sits beside the existing
`DatabaseBrowsing`:

```swift
public protocol DatabaseWriting: Sendable {
    func row(for service: DatabaseService, database: String, table: DatabaseTable,
             key: [String: String?]) throws -> [String: String?]
    func insert(for service: DatabaseService, database: String, table: DatabaseTable,
                values: [String: String?]) throws
    func update(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], changes: [String: String?],
                expected: [String: String?]) throws
    func delete(for service: DatabaseService, database: String, table: DatabaseTable,
                key: [String: String?], expected: [String: String?]) throws
}
```

`DatabaseBrowser` conforms to both. `DatabasesModel` takes an
`(any DatabaseBrowsing & DatabaseWriting)?`, so the `paddock db` commands
keep an interface without writes and cannot grow them by accident.

Values are `[column: text]`, with `nil` meaning SQL NULL. Text is the one
representation every PDO driver returns and accepts; the database casts
it to the column's type. An empty string and NULL stay distinct.

### Transport

Reads keep their request in `PADDOCK_DB_REQUEST` (base64 JSON in the
environment). A write can carry a long text or JSON value, which can
outgrow macOS's environment limits, so write requests travel in a private
temporary file whose path is given in `PADDOCK_DB_REQUEST_FILE`. The file
is created 0600, read and removed by PHP, and removed again by Swift on
return. Its content is the same JSON shape, plus `key`, `changes` and
`expected`.

### The PHP program

Four new actions, all building their own SQL:

- `row`: `SELECT *` by key in a read-only transaction. Values are
  returned whole, not clipped at 4096. Binary columns are left out. An
  unreadable request file fails with a plain message.
- `insert`: `INSERT INTO t (columns…) VALUES (?, …)`. The column list is
  the keys of `values`; a fully defaulted insert uses `DEFAULT VALUES`
  on PostgreSQL and `() VALUES ()` on MySQL.
- `update`: a normal transaction; see the conflict check below. An
  update with no changes is never sent.
- `delete`: a normal transaction; see the conflict check below.

Identifiers go through the existing `ident()` quoting; schema-qualified
names are quoted piece by piece. Every value is a bound parameter.
MySQL connections set `PDO::MYSQL_ATTR_FOUND_ROWS`, so a save that
changes nothing still reports the row as matched.

Limits: PostgreSQL gets `SET LOCAL statement_timeout = '5s'`; MySQL gets
`innodb_lock_wait_timeout = 5` (its `max_execution_time` covers reads
only). The 30-second PHP process timeout remains the backstop. Any error
rolls the transaction back before its message is returned.

## What can be edited

The `columns` read learns three flags from `information_schema`:

- `binary`: `bytea`; `binary`, `varbinary`, the BLOB family, geometry on
  MySQL. Never sent, never compared, never written.
- `generated`: PostgreSQL `is_generated` is not `NEVER`; MySQL `extra`
  says `GENERATED`. Computed by the database, never written.
- `identity`: PostgreSQL `is_identity` or a `nextval(…)` default;
  MySQL `auto_increment`. Shown, used as the key, but not editable — the
  database assigns it.

A column is editable when it is none of these. On update only changed,
editable columns are sent; identity and generated columns are left alone.
On insert only fields the owner touched are sent, so every other column
takes its default. The key may itself be an identity column; that is
fine, it is still read and matched.

## Identity and the conflict check

A table qualifies when it has at least one primary key column. The key is
all of them, in column order. Views and keyless tables keep their rows
but lose the actions column and the + button; the toolbar says
"Read-only: no primary key" instead.

Opening a row calls `row(key)` and gets the owner's current values,
whole. The editor works from those values, never from the clipped grid
text.

Saving and deleting run these steps inside one read-write transaction:

1. `SELECT * FROM t WHERE key IS NOT DISTINCT FROM ? … FOR UPDATE`
   (PostgreSQL) or the same with `<=>` (MySQL), binding the key.
2. No row: refuse — the row is gone.
3. Compare the row just read, value by value, with `expected` (the
   values the editor opened with), using the same text conversion the
   `row` read used but without its 4096-character clipping — otherwise a
   change past the clip would go unseen. Any difference: refuse — the
   row changed since it was read.
4. Apply the `UPDATE` or `DELETE`, then commit.

Note: this refines design section 1(d). The owner approved "the WHERE
matches the key AND every original value, NULL-safe". Comparing inside
the transaction against a `FOR UPDATE` read reaches the same guarantee,
and avoids the cases where a value cannot sit in a WHERE at all
(PostgreSQL's `json` and `xml` have no equality operator; the full-row
WHERE would have to leave them out, weakening the check). One mechanism,
both engines, no type exceptions.

`expected` holds only columns the `row` read returns — the non-binary
ones. A concurrent change confined to a BLOB column is therefore not
detected; Paddock never writes that column, so it cannot be lost by this
save.

The messages:

- `This row changed since it was read. Reload and try again.`
- `That row is no longer there. It may have been deleted.`

The editor keeps the owner's text on either, so nothing typed is lost.

## What the window does

### Toolbar

Beside the search, the row count and Reload:

- **+ New row** — editable tables only. Opens a blank row at the grid's
  end and scrolls to it.
- **Read-only: no primary key** — a quiet line in place of the button,
  for views and keyless tables.
- A quiet status line: `Saved.`, `Added.`, `Deleted.`, or the database's
  own error. It survives the reload that follows a write and clears when
  the owner moves to another table, database or service.

### Rows

A trailing actions column holds a pencil and a trash, shown on the row
under the pointer or the selected row. Double-clicking a row also edits
it. The same two actions are in the row's context menu.

### Editing in place

- The row's cells become monospaced text fields; the row grows a little.
  Return and Tab move between fields. Esc cancels; ⌘⏎ saves.
- A field whose value is NULL shows a dimmed `NULL`; a small ∅ toggle
  beside nullable fields sets and clears NULL. Empty text is not NULL.
- Binary, generated and identity fields are disabled, showing their
  values, with a tooltip saying why.
- Save is enabled only when something changed. Cancel is always enabled.
- JSON and JSONB fields open the existing inspector as an editable box
  (apply/cancel inside it). The text is checked with `DatabaseJSON`
  before any write, and a bad document is refused with a line naming the
  column.
- While the write is in flight the row is disabled and shows its
  progress; a failure leaves it open and editable.

### New records

+ opens a blank row at the end. Fields carry a placeholder: `default`
when the column has a default, `required` when it is NOT NULL without
one, `NULL` when nullable. ∅ toggles set NULL explicitly. Untouched
fields are omitted from the INSERT; Save inserts even a row where
nothing was typed, which is a legitimate all-defaults row.

After an insert the table reloads. The new row may not be among the first
50 or may not match the search; the status line still says `Added.`

### Deleting

The trash asks first: “Delete the row where id = 42 from shop.users?
This can't be undone.” The key's columns and values are named; NULL keys
are impossible. Delete is the destructive button; Cancel is the default.
Afterwards the table reloads and the status line says `Deleted.`

### Unsaved work

Starting another edit, another table, another service or another
database with a row open asks “Discard the unsaved row?” and only
discards on yes. Closing the window keeps the open row: the model lives
for the app's lifetime, and reopening the window shows the draft intact.

### Wording

The window's closing line changes from “Nothing here changes a database”
to: reads run in read-only transactions, the console can't write, and
row edits are individual, confirmed writes.

## Errors

| Situation | What is shown |
| --- | --- |
| Conflict on save/delete | The two sentences above; editor stays open |
| Constraint violation (unique, FK, NOT NULL, check) | The database's message, verbatim |
| Bad JSON (client check) | “The <column> value isn't valid JSON.” |
| Column vanished (schema changed) | The database's message; reload offers the new shape |
| Service stopped / PHP missing | The existing messages, unchanged |

## Edge cases

- Composite primary keys: the key is every primary column; the dialog
  names each.
- Editing a non-identity key: `WHERE` uses the original key, `SET` uses
  the new value.
- NULL primary key: impossible by definition.
- Identity key: shown read-only, still matched and named.
- Rows beyond the first 50: not edited; only shown rows can be opened.
- Search active: saves reload under the same search; a row that no
  longer matches disappears, and the status line explains.
- Empty table with + : works; without a defaulted insert the database's
  NOT NULL error is shown.
- A trigger changes values during the write: the conflict check already
  passed; the row simply shows the new values after reload.
- MySQL `ON UPDATE CURRENT_TIMESTAMP` on a column outside `changes`:
  untouched by the save; the update's own row count stays 1.
- Very long values: carried by the request file; the editor is a normal
  text view.
- Two windows on the same table: both can edit; the second save gets the
  conflict message.

## Testing

- **Unit (`PaddockCoreTests`)**
  - The draft: dirty detection, NULL versus empty text, change and
    expected maps, key derivation (single and composite), insert's
    touched-only values, placeholder choice, JSON validation.
  - `DatabasesModel` with a fake browser/writer: begin edit loads the
    row, save sends exactly the changed columns, conflict keeps the
    editor and its text, delete reloads, read-only tables hide the
    actions, notice text.
- **Integration (real PostgreSQL and MySQL)**
  - Insert: defaults, explicit NULL, identity omitted, all-default row.
  - Update: one column; renaming a key; a no-op save on MySQL.
  - Conflict: the row is changed through a second connection between
    the fresh read and the save; both engines refuse, and nothing is
    written.
  - Delete: gone afterwards; a second delete says the row is gone.
  - Constraint errors surface the database's message.
  - Views and keyless tables are refused by the writer.
- **Snapshots**: edit mode, new row with placeholders and ∅, read-only
  note, status line; light and dark. The delete dialog is verified by
  hand (SwiftUI alerts don't render in snapshots).
- **Full suite** before release.

## Docs and release

- README's Databases section is rewritten: editing rules, what stays
  read-only, the console's guarantee.
- `docs/images/databases-light.png` is regenerated with the actions
  column.
- Release notes: 0.3.1 (already written) covers the JSON cells, column
  widths and clipping fixes now in the working tree; this feature is
  0.4.0. Build 24, VERSION 0.4.0.
- Publishing either release happens only when the owner asks.

## Files, roughly

- `Sources/PaddockCore/Database/DatabaseEditing.swift` — write protocol,
  result and errors, draft and key derivation.
- `Sources/PaddockCore/Database/DatabaseBrowser.swift` — conformance,
  new flags on `DatabaseColumn`.
- `Sources/PaddockCore/Database/PHPDatabaseBridge.swift` — request file,
  four actions, metadata flags.
- `Sources/PaddockCore/App/DatabasesModel.swift` — editor state, saves,
  deletes, notices.
- `Sources/PaddockApp/Databases/DatabasesView.swift` — actions column,
  in-place editor, NULL toggles, JSON editor, dialog, toolbar.
- `Sources/PaddockApp/Snapshots.swift` — sample writable/keyless tables
  and new shots.
- Tests under `Tests/PaddockCoreTests`, `Tests/IntegrationTests`.
