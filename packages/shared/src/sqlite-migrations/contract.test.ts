import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { sqliteMigrations, MigrationChecksumError } from "./index.js";

it("backs up only declared tables, rejects changed checksums and restores data", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-migration-"));
  const db = new DatabaseSync(join(root, "index.sqlite"));
  try {
    db.exec(
      "CREATE TABLE tasks(id TEXT PRIMARY KEY,title TEXT); INSERT INTO tasks VALUES('one','original'); CREATE TABLE private(value TEXT); INSERT INTO private VALUES('untouched');",
    );
    const migration = {
      id: "0001_projects",
      appVersion: "2.0.12",
      sql: "UPDATE tasks SET title='new';",
      touchedTables: ["tasks"],
    };
    const result = await sqliteMigrations.migrate(db, [migration], {
      database: "tasks_index",
      backupDirectories: [root],
    });
    expect(result.backupPath).toBeDefined();
    expect(db.prepare("SELECT title FROM tasks").get()?.title).toBe("new");
    expect(
      (
        await sqliteMigrations.migrate(db, [migration], {
          database: "tasks_index",
          backupDirectories: [root],
        })
      ).applied,
    ).toEqual([]);
    await expect(
      sqliteMigrations.migrate(db, [{ ...migration, sql: "DELETE FROM tasks;" }], {
        database: "tasks_index",
        backupDirectories: [root],
      }),
    ).rejects.toBeInstanceOf(MigrationChecksumError);
    await sqliteMigrations.restore(db, result.backupPath!);
    expect(db.prepare("SELECT title FROM tasks").get()?.title).toBe("original");
    expect(db.prepare("SELECT value FROM private").get()?.value).toBe("untouched");
  } finally {
    db.close();
    await rm(root, { recursive: true, force: true });
  }
});

it("rolls back all writes and refuses missing touched tables", async () => {
  const root = await mkdtemp(join(tmpdir(), "ccbuddy-migration-rollback-"));
  const db = new DatabaseSync(":memory:");
  try {
    db.exec("CREATE TABLE tasks(id TEXT)");
    const options = { database: "tasks_index", backupDirectories: [root] };
    await expect(
      sqliteMigrations.migrate(
        db,
        [
          {
            id: "invalid",
            appVersion: "2.0.12",
            sql: "INSERT INTO tasks VALUES('bad');",
            touchedTables: [],
          },
        ],
        options,
      ),
    ).rejects.toThrow("touchedTables");
    await expect(
      sqliteMigrations.migrate(
        db,
        [
          {
            id: "failure",
            appVersion: "2.0.12",
            sql: "INSERT INTO tasks VALUES('bad'); SELECT * FROM missing;",
            touchedTables: ["tasks"],
          },
        ],
        options,
      ),
    ).rejects.toThrow();
    expect(db.prepare("SELECT count(*) AS count FROM tasks").get()?.count).toBe(0);
    expect(db.isTransaction).toBe(false);
  } finally {
    db.close();
    await rm(root, { recursive: true, force: true });
  }
});
