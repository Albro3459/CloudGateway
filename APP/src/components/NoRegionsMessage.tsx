import React from "react";

export const SUPPORT_EMAIL = "Brodsky.Alex22@gmail.com";

// Shared empty-regions message used by Login, Home, and CreateUser. Renders
// inline (a fragment) so it can sit inside an existing banner or paragraph.
export const NoRegionsMessage: React.FC = () => (
    <>
        No enabled regions are available.{" "}
        <a href={`mailto:${SUPPORT_EMAIL}`} className="underline">
            Contact an admin
        </a>{" "}
        for access to CloudGateway.
    </>
);
