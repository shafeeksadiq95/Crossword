RCM QUEST v6 — SINGLE WEBSITE / AUTOMATIC ROLE ROUTING
=========================================================

Everyone uses one root website link, for example:
https://rcmquest.healthreconconnect.com

LOGIN FIELDS
------------
1. Employee Name
2. HRC Email Address

AUTOMATIC ROUTING
-----------------
Exact admin credentials:
Name: Shafeek Sadiq
Email: shafeeks@healthreconconnect.com

These route automatically to the Admin Console.

Any other valid @healthreconconnect.com email routes automatically to the Employee Crossword Interface.
The employee does not need to choose a role.

SITE STRUCTURE
--------------
/index.html       Common login / automatic role routing
/user/index.html  Employee crossword experience
/admin/index.html Admin Console
/config.js        Shared configuration
/supabase-setup.sql Shared production database

LOGOUT
------
Both Admin and Employee logout return to the same common login page.

COMPANY-WIDE PRODUCTION
-----------------------
1. Create a Supabase project.
2. Enable Anonymous Sign-Ins.
3. Run supabase-setup.sql.
4. Copy the Project URL and Publishable/Anon key.
5. Update config.js:
   DEMO_MODE: false
   SUPABASE_URL: "..."
   SUPABASE_ANON_KEY: "..."
6. Publish the full folder to Azure Static Web Apps or another approved static host.
7. Point an HRC DNS entry such as rcmquest.healthreconconnect.com to the hosted app.
8. Share only the root company link with employees.

SECURITY NOTE
-------------
This version follows the requested typed Name + Email routing. For production administration, Microsoft Entra ID / HRC SSO is recommended so only the real Shafeek account can enter the Admin Console. The user-facing routing experience can remain the same after SSO is added.
