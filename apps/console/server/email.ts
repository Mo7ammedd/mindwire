import nodemailer from "nodemailer";
import { env } from "./env";

const { smtp } = env;

// Authenticated providers and trusted relays are both supported. Partial credentials or an invalid
// port disable delivery uniformly, before any account lookup, without breaking the rest of Console.
export const emailDeliveryEnabled = Boolean(
  smtp.host &&
    smtp.from &&
    Number.isInteger(smtp.port) &&
    smtp.port > 0 &&
    smtp.port <= 65535 &&
    Boolean(smtp.user) === Boolean(smtp.password),
);

const transport = emailDeliveryEnabled
  ? nodemailer.createTransport({
      host: smtp.host,
      port: smtp.port,
      secure: smtp.port === 465,
      requireTLS: true,
      ...(smtp.user && smtp.password
        ? { auth: { user: smtp.user, pass: smtp.password } }
        : {}),
      connectionTimeout: 10_000,
      greetingTimeout: 10_000,
      socketTimeout: 20_000,
      disableFileAccess: true,
      disableUrlAccess: true,
    })
  : null;

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (character) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[character]!,
  );
}

/** Better Auth owns token creation, expiry and consumption; this module only delivers the link. */
export async function sendPasswordResetEmail(
  to: string,
  url: string,
): Promise<void> {
  if (!transport) throw new Error("Account email delivery is not configured.");
  const appName = env.appName === "MindWire" ? "Mindwire" : env.appName;
  const name = escapeHtml(appName);
  const link = escapeHtml(url);
  try {
    const result = await transport.sendMail({
      from: smtp.from,
      to,
      subject: `Reset your ${appName} password`,
      text: `Reset your ${appName} password\n\nOpen this link to choose a new password:\n${url}\n\nThis link expires in one hour and can only be used once. If you didn't request this, you can ignore this email.`,
      html: `<div style="background:#f5f3ef;padding:40px 20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#252421"><div style="max-width:480px;margin:auto;background:#fff;border-radius:24px;padding:36px"><p style="font-weight:600;margin:0 0 32px">${name}</p><h1 style="font-size:26px;line-height:1.2;margin:0 0 16px">Reset your password</h1><p style="font-size:15px;line-height:1.6">Choose a new password for your ${name} account.</p><p style="margin:28px 0"><a href="${link}" style="display:inline-block;background:#252421;color:#fff;text-decoration:none;border-radius:12px;padding:14px 22px;font-weight:600">Reset password</a></p><p style="font-size:13px;line-height:1.6;color:#64615b">This link expires in one hour and can only be used once. If you didn't request this, you can ignore this email.</p><p style="font-size:12px;line-height:1.6;color:#64615b">If the button doesn't open, copy this link into your browser:<br><a href="${link}" style="color:#64615b;word-break:break-all">${link}</a></p></div></div>`,
    });
    if (!result.accepted?.length) throw new Error("SMTP recipient rejected.");
  } catch {
    // Raw SMTP errors may contain recipients, tokens or provider responses. Keep account details out
    // of logs and return the same recovery response for registered and unregistered email addresses.
    console.error(
      "[console] Password reset email delivery failed. Check SMTP settings and provider delivery logs.",
    );
  }
}
