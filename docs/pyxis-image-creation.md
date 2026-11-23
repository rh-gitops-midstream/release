# Adding a New Image in Pyxis

This guide outlines the end-to-end workflow for registering a new product image in the [Pyxis repository]([https://gitlab.cee.redhat.com/releng/pyxis-repo-configs](https://gitlab.cee.redhat.com/releng/pyxis-repo-configs)), retrieving its generated production ID, and linking it to the product listing configuration.

## End-to-End Workflow Summary

| Phase | Target Location / Environment | Key Action |
|---------|-------------|---------------------|
| Phase 1 | pyxis/products/ | Create image YAML file with mandatory fields and open PR #1 |
| Phase 2 | Terminal / Production CLI | Authenticate via kinit and fetch the generated image ID via pyxie |
| Phase 3 | pyxis/products/product-listing/ | Add the new image ID under the repositories section and open PR #2 |

## Step-by-Step Instructions

### Phase 1: Register the Image Definition

1. Navigate to the Products Directory: Clone or pull the latest changes from the pyxis repository and navigate to the products/ folder.
2. Create the YAML Configuration File: Create a new .yaml file inside the products/ folder following your team's naming convention (e.g., .yaml).
3. Populate Mandatory Fields: Fill out all required fields in the YAML file. Refer to the [example](https://gitlab.cee.redhat.com/releng/pyxis-repo-configs#product-example) for exact schema requirements, formatting rules, and validation constraints.
4. Submit Pull Request #1: Commit your new YAML file to a feature branch, push it to the remote repository, and open a Pull Request (PR).
5. Await Merge: Have your PR reviewed and merged into the main branch before proceeding to Phase 2.

### Phase 2: Authenticate & Retrieve the New Image ID

Once PR #1 is merged and processed by Pyxis, retrieve the newly assigned production ID for the image:

1. Authenticate with Kerberos: Open your terminal and initialize your Kerberos ticket using your username:

kinit . You should be connected to VPN (Refer [doc](https://gitlab.cee.redhat.com/releng/comet2cicada-documentation/-/blob/main/09-pyxie-cli-guide-for-product-owners.md) for pyxis installations)
2. Query Team Repositories: Run the following pyxie CLI command to inspect your team's repositories in production and locate the newly generated image ID:
`pyxie --env prod --output-format yaml get-team-repos --id <team-id>`
3. Copy the Image ID: Locate the entry corresponding to the image you created in Phase 1 and copy its newly generated ID.

### Phase 3: Update the Product Listing

1. Navigate to Product Listing: In the pyxis repository, pull the latest changes from main and navigate to products/product-listing/.
2. Add the Image ID: Inside the product-listings/ folder, open your teams product listing configuration file, locate the repositories section, and append the copied image ID.
3. Submit Pull Request #2: Commit the updated product listing file to a new branch, push the changes, and create a second PR.
4. Verify Deployment: Once PR #2 is approved and merged, confirm that the image appears properly under the product listing.

## Quick Reference Checklist

- [ ] Created new .yaml file in pyxis/products/ with all mandatory fields.
- [ ] Merged PR #1 into the main branch.
- [ ] Authenticated via `kinit <username>`
- [ ] Retrieved new image ID using `pyxie --env prod --output-format yaml get-team-repos --id <team-id>`
- [ ] Added image ID to the repositories section inside pyxis/product-listing/.
- [ ] Created and merged PR #2.
