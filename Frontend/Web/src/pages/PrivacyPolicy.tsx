import React from "react";
import { useNavigate } from "react-router-dom";
import { FontAwesomeIcon } from "@fortawesome/react-fontawesome";
import { faArrowLeft, faHouse } from "@fortawesome/free-solid-svg-icons";
import { ThemeToggle } from "../components/ThemeToggle";
import { SUPPORT_EMAIL } from "../components/AccessMessages";

const thirdPartyServices = [
    {
        name: "Firebase Authentication",
        href: "https://firebase.google.com/support/privacy",
    },
    {
        name: "Firebase / Firestore",
        href: "https://firebase.google.com/support/privacy",
    },
    {
        name: "Google Sign-In",
        href: "https://policies.google.com/privacy",
    },
    {
        name: "Sign in with Apple",
        href: "https://www.apple.com/legal/privacy/",
    },
    {
        name: "Cloudflare",
        href: "https://www.cloudflare.com/privacypolicy/",
    },
    {
        name: "Oracle Cloud Infrastructure",
        href: "https://www.oracle.com/legal/privacy/",
    },
    {
        name: "AWS SES Email",
        href: "https://aws.amazon.com/privacy/",
    },
];

const PrivacyPolicy: React.FC = () => {
    const navigate = useNavigate();

    return (
        <div className="min-h-screen bg-page px-4 pb-12 pt-24 text-content">
            <nav className="fixed left-0 top-0 z-40 flex w-full items-center justify-center bg-nav px-6 py-4 text-white shadow-md">
                <button
                    type="button"
                    onClick={() => navigate(-1)}
                    aria-label="Go back"
                    className="absolute left-6 cursor-pointer text-2xl text-accent transition hover:text-accent-strong"
                >
                    <FontAwesomeIcon icon={faArrowLeft} />
                </button>
                <h1 className="text-xl font-semibold">Privacy Policy</h1>
                <div className="absolute right-6 flex items-center gap-4">
                    <button
                        type="button"
                        onClick={() => navigate("/home")}
                        aria-label="Home"
                        className="cursor-pointer text-xl text-accent transition hover:text-accent-strong"
                    >
                        <FontAwesomeIcon icon={faHouse} />
                    </button>
                    <ThemeToggle />
                </div>
            </nav>

            <main className="mx-auto w-full max-w-4xl">
                <section className="rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <p className="mb-2 text-sm text-content-muted">Effective July 5, 2026</p>
                    <h2 className="mb-4 text-3xl font-semibold">CloudGateway Privacy Policy</h2>
                    <p className="text-content-secondary">
                        This privacy policy applies to the CloudGateway app and service operated by Alex Brodsky.
                        CloudGateway is a free, invite-only VPN configuration service. Guest mode is available with
                        limited access, but creating and using VPN clients requires an invited account.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Information CloudGateway Collects</h3>
                    <p className="mb-4 text-content-secondary">
                        CloudGateway keeps user-provided personal information intentionally small. The service collects:
                    </p>
                    <ul className="list-disc space-y-2 pl-6 text-content-secondary">
                        <li>Your email address for account access, authentication, support, and service administration.</li>
                        <li>The display name you choose for a VPN configuration.</li>
                    </ul>
                    <p className="mt-4 text-content-secondary">
                        CloudGateway also creates and maintains service records needed to operate invited access and VPN
                        configuration. These records are used to run the service and are not used for third-party
                        advertising or tracking across other companies' apps or websites.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">VPN Traffic And Activity</h3>
                    <p className="text-content-secondary">
                        CloudGateway does not store or log VPN user traffic or activity. CloudGateway does not store or
                        log browsing history, DNS queries, destination domains, destination IP addresses, packet
                        contents, per-site activity, or per-user connection history.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">VPN Configuration Material</h3>
                    <p className="text-content-secondary">
                        To provide VPN service, CloudGateway creates VPN configuration material for provisioned clients.
                        On iOS, installed VPN configuration material is stored locally in the device Keychain. The app
                        uses this material to install and start the VPN profile. CloudGateway does not use this material
                        for advertising or user tracking.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">API And Operational Logs</h3>
                    <p className="text-content-secondary">
                        CloudGateway keeps API and operational logs to run, secure, debug, and maintain the service.
                        These logs may include request metadata such as timestamps, request paths, status codes, source
                        IP addresses, user agents, authentication context, and error details. CloudGateway does not set a
                        fixed deletion date for these operational logs.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Third-Party Services</h3>
                    <p className="mb-4 text-content-secondary">
                        CloudGateway uses third-party services to provide authentication, storage, infrastructure,
                        security, and email delivery. These providers have their own privacy policies.
                    </p>
                    <ul className="grid gap-3 sm:grid-cols-2">
                        {thirdPartyServices.map((service) => (
                            <li key={service.name}>
                                <a
                                    href={service.href}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                    className="block rounded-lg border border-edge bg-inset px-4 py-3 text-accent underline transition hover:bg-inset-strong hover:text-accent-strong"
                                >
                                    {service.name}
                                </a>
                            </li>
                        ))}
                    </ul>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Analytics And Crash Reporting</h3>
                    <p className="text-content-secondary">
                        CloudGateway does not use analytics or crash-reporting SDKs in the iOS app.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Data Retention And Deletion</h3>
                    <p className="text-content-secondary">
                        CloudGateway retains account and service data for as long as needed to provide and administer the
                        service. You may delete your account from the account menu in the CloudGateway app or web
                        dashboard. You may also request account deletion by contacting{" "}
                        <a href={`mailto:${SUPPORT_EMAIL}`} className="text-accent underline hover:text-accent-strong">
                            {SUPPORT_EMAIL}
                        </a>
                        . CloudGateway will delete your account and associated service data in a reasonable time, except
                        where retention is needed for security, abuse prevention, legal compliance, or service operations.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Children</h3>
                    <p className="text-content-secondary">
                        CloudGateway is not directed to children under 13. CloudGateway does not knowingly collect
                        personal information from children under 13. If you believe a child has provided personal
                        information to CloudGateway, contact Alex Brodsky at{" "}
                        <a href={`mailto:${SUPPORT_EMAIL}`} className="text-accent underline hover:text-accent-strong">
                            {SUPPORT_EMAIL}
                        </a>
                        .
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Security</h3>
                    <p className="text-content-secondary">
                        CloudGateway uses technical and administrative safeguards designed to protect service data.
                        No method of transmission or storage is perfect, but CloudGateway works to limit the amount of
                        user-provided personal information it collects and to protect the information it maintains.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Changes</h3>
                    <p className="text-content-secondary">
                        This policy may be updated from time to time. Updates will be posted on this page. Continued use
                        of CloudGateway after an update means you accept the updated policy.
                    </p>
                </section>

                <section className="mt-6 rounded-2xl border border-edge bg-card p-6 shadow-lg md:p-8">
                    <h3 className="mb-3 text-2xl font-semibold">Contact</h3>
                    <p className="text-content-secondary">
                        If you have privacy questions about CloudGateway, contact Alex Brodsky at{" "}
                        <a href={`mailto:${SUPPORT_EMAIL}`} className="text-accent underline hover:text-accent-strong">
                            {SUPPORT_EMAIL}
                        </a>
                        .
                    </p>
                </section>
            </main>
        </div>
    );
};

export default PrivacyPolicy;
