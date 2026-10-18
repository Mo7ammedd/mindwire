CREATE TABLE `push_device` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`owner_id` text NOT NULL,
	`device_id` text NOT NULL,
	`token_ciphertext` text NOT NULL,
	`token_hash` text NOT NULL,
	`platform` text NOT NULL,
	`device_info` text,
	`status` text DEFAULT 'active' NOT NULL,
	`created_at` integer NOT NULL,
	`last_seen_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `push_device_owner_device` ON `push_device` (`owner_id`,`device_id`);--> statement-breakpoint
CREATE INDEX `push_device_owner_status` ON `push_device` (`owner_id`,`status`);--> statement-breakpoint
CREATE TABLE `push_token` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`owner_id` text NOT NULL,
	`workspace_id` text,
	`tag` text,
	`token_hash` text NOT NULL,
	`token_prefix` text NOT NULL,
	`name` text,
	`metadata` text,
	`status` text DEFAULT 'active' NOT NULL,
	`created_at` integer NOT NULL,
	`last_used_at` integer,
	`expires_at` integer,
	`revoked_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `push_token_hash` ON `push_token` (`token_hash`);--> statement-breakpoint
CREATE UNIQUE INDEX `push_token_owner_tag` ON `push_token` (`owner_id`,`tag`);--> statement-breakpoint
CREATE INDEX `push_token_owner_status` ON `push_token` (`owner_id`,`status`);