# Shared VPN Server

## Potential steps

* Verify the efficacy of the plan
* Figure out what the Python API will actually do
* Update the cloud-init script to deploy everything
* Pain
* Fully update the Python API
* Cleanup Firebase
* Fully update the UI
* Test the fuck out the bitch lol
* Chicago will probably be the test region

---

## Server / Backend

* 1 independent server
* 2 cores, 8 - 12 GB RAM :)
* I don't think it even needs to know what region it is
* Cloudflare DNS records to connect to the correct VPN server
    * Ex: `us-sanjose-1.gocloudlaunch.com/api/` to connect to the specific region
* Frontend will pull the current domains from Firebase
* DynamoDB needs to be migrated into Firebase
    * Should be easy cause `roles` gets the limits and `users` gets the counts
* It could just count how many running + pending for the count to make it easier
* 1 singular Python API, maybe FastAPI
* Connect all shared code
* Firebase, secrets, stuff like that
* No more duplication
* Firebase auth verification on the server like StreamTrack does
* No more deploying or terminating VPN servers

### API Actions

Now probably just need:
* Create user
* Add client
* Remove client

(Regions will just be pulled from Firebase as the source of truth.)

* This will make load times for regions much shorter
* (Secrets don't need to be pulled cause configs now live in Firebase)
* Use `os` library to interact with the actual WG files
* Some helper files will be needed for adding and removing
* Cloudflare proxy -> DNS records -> Caddy w/ rate limiting + specific paths only + maybe specific header for auth token -> API entry -> Firebase auth verification on the token
* Probably require requests come directly from Cloudflare if that is easy and maintainable (like the IPs are stable)
* Do this for StreamTrack if it's good
* Maybe even change the HTTPS port
    * Prolly not
* We want ad blocking too
    * AdGuard
    * Maybe the `ad-blocking-but-vm-too-weak` branch for an outdated reference using manual blocklists

### Cloud-init / Server Setup

* Update the cloud-init script to fully setup a VPN server
* Region, networking w/ IPv6, `tfvars` need to be setup
* Script needs to setup Python API and Caddy
* Docker Compose works nice for this and I've used it for StreamTrack, but might make the script a bitch
* Then setup the VPN like we already have, but without a client peer already added
* Unbound DNS recursive resolver
* Adblocking!!!!!
    * AdGuard
    * Wireguard -> Adguard -> Unbound
* 15 - 25 clients per server
    so * Can manage by checking how many in that region the user has

---

## React Frontend

* Firebase will fully be source of truth
* Pull regions and counts from there
* Table needs to have a tab for each region
* Sort VPNs by user name alphabetical, then created date at the bottom maybe?
* Add a created date
* Tapping on the IP addresses in the table or other pages needs to copy to clipboard
    * Hovering should show some type of copy icon popup

### Users

#### Normal users

* 3 clients per region
* No override needed
* Can see, add, and remove their own clients

#### Admins

* As many clients as space allows
* No overrides for anything needed
* Can see, add, and remove any users' clients

### UX

* Allow letting a user name their VPN and give a name when they create it
* Probably don't show that in the admin view cause privacy
* Remove client should have a confirm
* Add client has them pick a region
* Remove is selecting 1+ on a table and delete button + confirmation
* Only 1 region at a time
* We have region tabs so that should be fine

---

## Firebase

* Single source of truth

### Roles

* Will hold roles and their per-region limits

### Users

* Regions -> Instances
* That is how the count will be made
* Add nullable `name` field to instances

### Regions

* Will hold regions with region, like `us-sanjose-1`, as key probably and properties:
  * Display name
  * Enabled boolean
  * Max client count

### Want (not need)

* Sign in with Google so u don't need to remember ur password
    * How will that work with creating a guest account tho?
* Some way to switch auth to Sign in with Google?

---

## Cloudflare

* Will have DNS records for:
  * `<region>.gocloudlaunch.com/api/`
  * Ex: `us-sanjose-1.gocloudlaunch.com/api/`
* Will have proxy on and will map to VPN server in that region
* Probably remove the worker

---

## AWS

* Emails only
* Must still use AWS for sending emails cause it's 10x easier that way
* Remove Lambdas + Secrets