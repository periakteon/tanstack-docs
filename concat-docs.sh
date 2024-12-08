#!/bin/bash

# Clear the docs.md file first
> docs.md

# Loop through each markdown file in the guide directory
for file in guide/*.md; do
  # Add a separator line
  echo -e "\n---\n" >> docs.md
  
  # Add the filename as a header
  echo "# $(basename "$file" .md)" >> docs.md
  echo -e "\n" >> docs.md
  
  # Append the contents of the file
  cat "$file" >> docs.md
done

echo "Documentation has been concatenated into docs.md" 