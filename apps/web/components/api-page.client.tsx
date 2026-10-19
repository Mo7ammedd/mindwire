"use client";
import { createOpenAPIPage } from "fumadocs-openapi/ui";

// createOpenAPIPage() must be *called* on the client (it's a client factory). Building the component here,
// in a client module, lets the server wrapper (api-page.tsx) import it as a client reference and render it
// with serializable props. Shared Mindwire tokens and docs-theme.css supply the surfaces.
export const ClientAPIPage = createOpenAPIPage();
