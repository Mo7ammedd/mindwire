CREATE TABLE `cloud_computer` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`request_key` text NOT NULL,
	`namespace` text NOT NULL,
	`name` text NOT NULL,
	`state` text DEFAULT 'draft' NOT NULL,
	`contract` text NOT NULL,
	`workspace_id` text,
	`checkout_id` text,
	`checkout_url` text,
	`error` text,
	`lease_token` text,
	`lease_until` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `cloud_computer_request` ON `cloud_computer` (`owner_id`,`request_key`);--> statement-breakpoint
CREATE UNIQUE INDEX `cloud_computer_namespace` ON `cloud_computer` (`namespace`);--> statement-breakpoint
CREATE UNIQUE INDEX `cloud_computer_workspace` ON `cloud_computer` (`workspace_id`);--> statement-breakpoint
CREATE INDEX `cloud_computer_owner` ON `cloud_computer` (`owner_id`);--> statement-breakpoint
CREATE INDEX `cloud_computer_due` ON `cloud_computer` (`state`,`updated_at`);--> statement-breakpoint
CREATE TABLE `cloud_legacy_account` (
	`provider_id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`credential` text NOT NULL,
	`next_refresh_at` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `cloud_legacy_account_owner` ON `cloud_legacy_account` (`owner_id`);--> statement-breakpoint
CREATE INDEX `cloud_legacy_account_refresh` ON `cloud_legacy_account` (`next_refresh_at`);