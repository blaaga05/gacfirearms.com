# GAC public merchandise preview

Public navigation: /#merch. Public guest cart in the header, no member account required. Shirt photo supplied by owner. Starting example price $30, sizes S/M/L/XL/2XL/3XL; owner can change these.

Owner account: Admin > Merch. Edit name, description, price, sizes/options, image URL and public visibility; add new products. Products without sizes can use One size. Hidden products remain owner-visible but are absent from the public catalog and removed from guest carts on refresh. Quantity selector is per-cart and does not represent stock.

Catalog in public.gac_merch_products with RLS enabled. Public users read only published products; authenticated private owners may read/write all. Owner identity uses existing private owner function, never user metadata. No other member/order/recognition schema is changed.

Cart stores product ID, size and quantity in localStorage only. Product names, prices, shipping, and stock are loaded afresh from the catalog. Cached/client prices are ignored. Before checkout, the customer enters a US delivery address. A trusted Edge Function calculates Georgia tax from the delivery county using `georgia-sales-tax.mjs` and the effective DOR quarter chart; non-Georgia delivery is untaxed while GAC has no collection obligation there. The customer reviews the server total before Authorize.Net. A 20-minute inventory hold begins only after the server prices the order. Card data stays on Authorize.Net. Do not store delivery details in browser local storage.

Tests: 66 Node checks pass, including cart merge/validation/current pricing; rollback SQL confirmed public read, anonymous/member writes denied, owner edits permitted and rolled back. Security advisors reported no catalog-specific warning. DOM interaction checks passed for public product display, adding/updating/removing cart items, owner-only editor loading and saving a changed price. Browser visual QA unavailable in this environment; static layout and module checks performed. No live payment tests or payment settings changed for merchandise.
