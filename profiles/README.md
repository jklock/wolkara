# Application profiles

A profile tells the launcher what a tested application is called and where its
files live inside the Tolkara app's Documents folder. It is data only: no code,
no patches, no settings for the application itself.

```json
{
  "id": "example",
  "name": "Example",
  "workingDirectory": "Example",
  "executable": "Example.app/Contents/MacOS/Example",
  "tested": "Example 2.1, iPad Pro M5",
  "notes": "Anything a user should know."
}
```

- `workingDirectory`: folder under Documents that becomes the working directory.
- `executable`: path of the macOS executable, relative to `workingDirectory`.
  Keeping the `.app` bundle structure lets the application find its resources.
- Both paths must be relative and stay inside Documents; `tools/check_profile.py`
  rejects anything else and any unknown key.

Every profile in `profiles/` is built into the app. When the files a profile
describes are present in Documents, the launcher adds that app to its library
under the profile's name. A profile outside this folder can be added with
`TOLKARA_PROFILE=/path/to/profile.json` in `local.env`.

Profiles are optional: any executable added with **+** in the launcher is
remembered too. Inside Documents it runs in place (the folder containing its
`.app` becomes the working directory); elsewhere only the executable is copied.

A profile folder may include a helper script that copies the user's **own**
installed files to the iPad. It must never download or contain the application.
