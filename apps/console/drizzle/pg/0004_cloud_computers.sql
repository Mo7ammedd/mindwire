CREATE TABLE "cloud_computer" (
	"id" text PRIMARY KEY NOT NULL,
	"owner_id" text NOT NULL,
	"request_key" text NOT NULL,
	"namespace" text NOT NULL,
	"name" text NOT NULL,
	"state" text DEFAULT 'draft' NOT NULL,
	"contract" text NOT NULL,
	"workspace_id" text,
	"checkout_id" text,
	"checkout_url" text,
	"error" text,
	"lease_token" text,
	"lease_until" bigint DEFAULT 0 NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "cloud_legacy_account" (
	"provider_id" text PRIMARY KEY NOT NULL,
	"owner_id" text NOT NULL,
	"credential" text NOT NULL,
	"next_refresh_at" bigint DEFAULT 0 NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_computer_request" ON "cloud_computer" USING btree ("owner_id","request_key");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_computer_namespace" ON "cloud_computer" USING btree ("namespace");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_computer_workspace" ON "cloud_computer" USING btree ("workspace_id");--> statement-breakpoint
CREATE INDEX "cloud_computer_owner" ON "cloud_computer" USING btree ("owner_id");--> statement-breakpoint
CREATE INDEX "cloud_computer_due" ON "cloud_computer" USING btree ("state","updated_at");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_legacy_account_owner" ON "cloud_legacy_account" USING btree ("owner_id");--> statement-breakpoint
CREATE INDEX "cloud_legacy_account_refresh" ON "cloud_legacy_account" USING btree ("next_refresh_at");