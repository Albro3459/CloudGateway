### Running React Site:

Update dependencies:
```sh
cd APP; 
npm install
```

Run the Cloudflare Worker in one terminal:
```sh
cd cloudflare
npm run dev
```

Run the React app in another terminal:
```sh
cd react-frontend; 
npm start
````

`npm start` sets `REACT_APP_API_ORIGIN=http://localhost:8787`, so local API calls go to the Worker instead of the React dev server. Production builds leave this unset and use same-origin `/api/*` paths on `gateway.gocloudlaunch.com`.

Keep tailwind css updated while making changes:
```sh
cd react-frontend; 
npx @tailwindcss/cli -i ./src/input.css -o ./src/output.css --watch
```

---

### Publish GitHub page:

* [CNAME](./public/CNAME) specifies the host name. This must match DNS records

* NOTE: This uses the your local build code to publish. It does NOT pull from any remote branch. It compiles your code to the build folder and publishes that. 
    * Pro: Can be ran from any branch
    * Con: Must be run locally and it can be confusing

```sh
cd APP; 
npm run publish # publishes to gh-pages branch
````
